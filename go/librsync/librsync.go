// Package librsync exposes the librsync FFI core as plain-Go functions so it
// can be linked into c-shared binaries without source copies.
//
// Each //export thunk in a `package main` wrapper calls the corresponding
// function here, doing only the C-pointer ↔ Go-slice translation at the
// boundary.  Function bodies live exclusively in this package.
package librsync

import (
	"fmt"
	"io"
	"os"
	"sync"
	"unsafe"

	librsync "github.com/balena-os/librsync-go"
	"github.com/balena-os/librsync-go/ffi/adapter"
)

// ── Error codes (Go-side mirror of the wire ABI) ──────────────────────────────

const (
	ErrOK      int32 = 0
	ErrArgs    int32 = -1
	ErrCorrupt int32 = -2
	ErrMem     int32 = -3
)

// Strerror returns a human-readable string for an error code, or empty
// string for ErrOK.  The thunk wraps this with C.CString.
func Strerror(code int32) string {
	switch code {
	case ErrOK:
		return ""
	case ErrArgs:
		return "invalid arguments"
	case ErrCorrupt:
		return "corrupt or unexpected input"
	case ErrMem:
		return "memory allocation failed"
	default:
		return "unknown error"
	}
}

// ── Handle registry ──────────────────────────────────────────────────────────

// Handle is the opaque integer identifier exchanged with C callers.  We use
// uintptr so the underlying type matches C.intptr_t on both 32-bit and
// 64-bit ABIs without leaking cgo types into this package.
type Handle uintptr

var (
	handles   = map[Handle]interface{}{}
	handlesMu sync.Mutex
	nextID    Handle = 1
)

func storeHandle(v interface{}) Handle {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h := nextID
	nextID++
	handles[h] = v
	return h
}

func loadHandle(h Handle) interface{} {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	return handles[h]
}

func dropHandle(h Handle) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	delete(handles, h)
}

// ── Batch API ────────────────────────────────────────────────────────────────

// Signature builds a serialized signature from a complete file buffer.
// Returns (bytes, ErrOK) or (nil, ErrCorrupt).
func Signature(input []byte, blockLen, strongLen, sigType uint32) ([]byte, int32) {
	out, err := adapter.SignatureBytes(input, blockLen, strongLen, librsync.MagicNumber(sigType))
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

// Delta computes a delta from serialized signature bytes against a new file
// buffer.  Returns (bytes, ErrOK) or (nil, ErrCorrupt).
func Delta(sig, input []byte) ([]byte, int32) {
	parsed, err := adapter.ParseSignature(sig)
	if err != nil {
		return nil, ErrCorrupt
	}
	out, err := adapter.DeltaBytes(parsed, input)
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

// Patch applies a delta to a complete base buffer.
func Patch(base, delta []byte) ([]byte, int32) {
	out, err := adapter.PatchBytes(base, delta)
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

// ── Parsed-signature handle ──────────────────────────────────────────────────

// SigParse parses a serialized signature into an in-memory structure and
// returns a handle (>0) or 0 on failure.
func SigParse(sig []byte) Handle {
	parsed, err := adapter.ParseSignature(sig)
	if err != nil {
		return 0
	}
	return storeHandle(parsed)
}

// SigFree releases a parsed-signature handle.
func SigFree(h Handle) { dropHandle(h) }

// ── Streaming signature ──────────────────────────────────────────────────────

func SignatureNew(blockLen, strongLen, sigType uint32) Handle {
	sess, err := adapter.NewSignatureSession(blockLen, strongLen, librsync.MagicNumber(sigType))
	if err != nil {
		return 0
	}
	return storeHandle(sess)
}

func SignatureFeed(h Handle, input []byte) ([]byte, int32) {
	sess, ok := loadHandle(h).(*adapter.SignatureSession)
	if !ok {
		return nil, ErrArgs
	}
	out, err := sess.Feed(input)
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

// SignatureEnd finalises the session and drops the handle.  Always drops
// the handle whether or not End succeeds — match the original C ABI.
func SignatureEnd(h Handle) ([]byte, int32) {
	sess, ok := loadHandle(h).(*adapter.SignatureSession)
	dropHandle(h)
	if !ok {
		return nil, ErrArgs
	}
	out, err := sess.End()
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

func SignatureFree(h Handle) { dropHandle(h) }

// SignatureFeedInto is the zero-allocation streaming variant.  Returns
// (bytesWritten, morePending, status).
func SignatureFeedInto(h Handle, input, dst []byte) (int, bool, int32) {
	sess, ok := loadHandle(h).(*adapter.SignatureSession)
	if !ok {
		return 0, false, ErrArgs
	}
	n, more, err := sess.FeedInto(input, dst)
	if err != nil {
		return 0, false, ErrCorrupt
	}
	return n, more, ErrOK
}

// SignatureEndInto drains remaining output into caller-owned dst.  When
// morePending is false the handle is dropped automatically.
func SignatureEndInto(h Handle, dst []byte) (int, bool, int32) {
	sess, ok := loadHandle(h).(*adapter.SignatureSession)
	if !ok {
		return 0, false, ErrArgs
	}
	n, more, err := sess.EndInto(dst)
	if err != nil {
		dropHandle(h)
		return 0, false, ErrCorrupt
	}
	if !more {
		dropHandle(h)
	}
	return n, more, ErrOK
}

// ── Streaming delta ──────────────────────────────────────────────────────────

func DeltaNew(sigHandle Handle) Handle {
	sig, ok := loadHandle(sigHandle).(*librsync.SignatureType)
	if !ok {
		return 0
	}
	sess, err := adapter.NewDeltaSession(sig)
	if err != nil {
		return 0
	}
	return storeHandle(sess)
}

func DeltaFeed(h Handle, input []byte) ([]byte, int32) {
	sess, ok := loadHandle(h).(*adapter.DeltaSession)
	if !ok {
		return nil, ErrArgs
	}
	out, err := sess.Feed(input)
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

func DeltaEnd(h Handle) ([]byte, int32) {
	sess, ok := loadHandle(h).(*adapter.DeltaSession)
	dropHandle(h)
	if !ok {
		return nil, ErrArgs
	}
	out, err := sess.End()
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

func DeltaFeedInto(h Handle, input, dst []byte) (int, bool, int32) {
	sess, ok := loadHandle(h).(*adapter.DeltaSession)
	if !ok {
		return 0, false, ErrArgs
	}
	n, more, err := sess.FeedInto(input, dst)
	if err != nil {
		return 0, false, ErrCorrupt
	}
	return n, more, ErrOK
}

func DeltaEndInto(h Handle, dst []byte) (int, bool, int32) {
	sess, ok := loadHandle(h).(*adapter.DeltaSession)
	if !ok {
		return 0, false, ErrArgs
	}
	n, more, err := sess.EndInto(dst)
	if err != nil {
		dropHandle(h)
		return 0, false, ErrCorrupt
	}
	if !more {
		dropHandle(h)
	}
	return n, more, ErrOK
}

func DeltaFree(h Handle) { dropHandle(h) }

// ── Streaming patch ──────────────────────────────────────────────────────────

// patchSession bundles the upstream PatchSession with the resources Go owns
// for the lifetime of the session (the C-heap buffer for the buf path or
// the *os.File for the path path).
type patchSession struct {
	sess  *adapter.PatchSession
	cData unsafe.Pointer // non-nil for buf path — freed via cFree on teardown
	cLen  int64
	file  *os.File // non-nil for path path — closed on teardown
	cFree func(unsafe.Pointer)
}

func (ps *patchSession) cleanup() {
	if ps.cData != nil && ps.cFree != nil {
		ps.cFree(ps.cData)
	}
	ps.cData = nil
	if ps.file != nil {
		ps.file.Close()
		ps.file = nil
	}
}

// ReadAtFunc matches adapter.ReadAtFunc — the closure supplied by the
// caller for random-access reads on the base file.
type ReadAtFunc = adapter.ReadAtFunc

// PatchNew creates a streaming patch session backed by a caller-supplied
// ReadAt closure.  The closure is invoked from Go threads so it must be
// thread-safe; the //export thunk that adapts a C function pointer into a
// closure is responsible for ensuring this.
func PatchNew(readAt ReadAtFunc) Handle {
	if readAt == nil {
		return 0
	}
	sess := adapter.NewPatchSession(readAt)
	return storeHandle(&patchSession{sess: sess})
}

// PatchNewBuf creates a streaming patch session backed by a C-heap buffer
// the caller has malloc'd.  Go takes ownership: on success, the buffer is
// freed via cFree when the session ends; on failure the caller frees.
func PatchNewBuf(data unsafe.Pointer, dataLen int64, cFree func(unsafe.Pointer)) Handle {
	readAt := func(offset int64, buf []byte) (int, error) {
		if offset >= dataLen {
			return 0, io.EOF
		}
		available := dataLen - offset
		n := int64(len(buf))
		if n > available {
			n = available
		}
		src := unsafe.Slice((*byte)(data), dataLen)
		copy(buf[:n], src[offset:])
		return int(n), nil
	}
	sess := adapter.NewPatchSession(readAt)
	return storeHandle(&patchSession{
		sess:  sess,
		cData: data,
		cLen:  dataLen,
		cFree: cFree,
	})
}

// PatchNewPath opens the file at [path] and reads the basis from disk on
// demand via os.File.ReadAt (pread on POSIX, overlapped I/O on Windows —
// both thread-safe and position-independent).
func PatchNewPath(path string) Handle {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	readAt := func(offset int64, buf []byte) (int, error) { return f.ReadAt(buf, offset) }
	sess := adapter.NewPatchSession(readAt)
	return storeHandle(&patchSession{sess: sess, file: f})
}

func PatchFeed(h Handle, delta []byte) ([]byte, int32) {
	ps, ok := loadHandle(h).(*patchSession)
	if !ok {
		return nil, ErrArgs
	}
	out, err := ps.sess.Feed(delta)
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

func PatchEnd(h Handle) ([]byte, int32) {
	ps, ok := loadHandle(h).(*patchSession)
	dropHandle(h)
	if !ok {
		return nil, ErrArgs
	}
	defer ps.cleanup()
	out, err := ps.sess.End()
	if err != nil {
		return nil, ErrCorrupt
	}
	return out, ErrOK
}

func PatchFeedInto(h Handle, delta, dst []byte) (int, bool, int32) {
	ps, ok := loadHandle(h).(*patchSession)
	if !ok {
		return 0, false, ErrArgs
	}
	n, more, err := ps.sess.FeedInto(delta, dst)
	if err != nil {
		return 0, false, ErrCorrupt
	}
	return n, more, ErrOK
}

func PatchEndInto(h Handle, dst []byte) (int, bool, int32) {
	ps, ok := loadHandle(h).(*patchSession)
	if !ok {
		return 0, false, ErrArgs
	}
	n, more, err := ps.sess.EndInto(dst)
	if err != nil {
		dropHandle(h)
		ps.cleanup()
		return 0, false, ErrCorrupt
	}
	if !more {
		dropHandle(h)
		ps.cleanup()
	}
	return n, more, ErrOK
}

func PatchFree(h Handle) {
	ps, ok := loadHandle(h).(*patchSession)
	if ok {
		ps.sess.Close()
		ps.cleanup()
	}
	dropHandle(h)
}

// ReadAtError formats a non-zero return code from a C read_at callback into
// a Go error.  Hosted here so the thunk in package main doesn't need to
// import "fmt" just for one Errorf.
func ReadAtError(retCode int32) error {
	return fmt.Errorf("librsync: read_at callback returned error %d", retCode)
}
