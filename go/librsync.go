package main

/*
#include <stdint.h>
#include <stdlib.h>

// Callback struct for random-access reads on the base file.
// Dart allocates this with calloc and keeps it alive for the patch session.
typedef struct {
    void* userdata;
    int32_t (*read_at)(void* userdata, int64_t offset, uint8_t* buf, size_t len, size_t* bytes_read);
} rs_read_seeker_t;

// Trampoline so Go can call the function pointer without unsafe casts.
static int32_t call_read_at(const rs_read_seeker_t* rs, int64_t offset, uint8_t* buf, size_t len, size_t* bytes_read) {
    return rs->read_at(rs->userdata, offset, buf, len, bytes_read);
}
*/
import "C"

import (
	"fmt"
	"io"
	"os"
	"sync"
	"unsafe"

	librsync "github.com/balena-os/librsync-go"
	"github.com/balena-os/librsync-go/ffi/adapter"
)

func main() {}

// ── Error codes ───────────────────────────────────────────────────────────────

const (
	errOK      = C.int32_t(0)
	errArgs    = C.int32_t(-1)
	errCorrupt = C.int32_t(-2)
	errMem     = C.int32_t(-3)
)

// librsync_strerror returns a newly-allocated C string describing code.
// The caller must free the returned pointer with librsync_free.
// Returns NULL for errOK — only call on non-zero codes.
//
//export librsync_strerror
func librsync_strerror(code C.int32_t) *C.char {
	switch code {
	case errOK:
		return nil
	case errArgs:
		return C.CString("invalid arguments")
	case errCorrupt:
		return C.CString("corrupt or unexpected input")
	case errMem:
		return C.CString("memory allocation failed")
	default:
		return C.CString("unknown error")
	}
}

// ── Memory ────────────────────────────────────────────────────────────────────

// librsync_free frees a buffer returned by this library.
//
//export librsync_free
func librsync_free(ptr unsafe.Pointer) {
	C.free(ptr)
}

// ── Handle registry ───────────────────────────────────────────────────────────

var (
	handles   = map[C.intptr_t]interface{}{}
	handlesMu sync.Mutex
	nextID    C.intptr_t = 1
)

func storeHandle(v interface{}) C.intptr_t {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	h := nextID
	nextID++
	handles[h] = v
	return h
}

func loadHandle(h C.intptr_t) interface{} {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	return handles[h]
}

func dropHandle(h C.intptr_t) {
	handlesMu.Lock()
	defer handlesMu.Unlock()
	delete(handles, h)
}

// ── Output helpers ────────────────────────────────────────────────────────────

// cInput wraps a C pointer+length as a Go byte slice without copying.
func cInput(ptr *C.uint8_t, n C.size_t) []byte {
	if n == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(ptr)), int(n))
}

// setOutput copies data to C-heap memory and writes the pointer and length to
// the caller's output parameters. Sets both to zero when data is nil/empty.
// The caller must librsync_free the returned pointer.
func setOutput(outPtr **C.uint8_t, outLen *C.size_t, data []byte) {
	if len(data) == 0 {
		*outPtr = nil
		*outLen = 0
		return
	}
	*outPtr = (*C.uint8_t)(C.CBytes(data))
	*outLen = C.size_t(len(data))
}

// ── Batch API ─────────────────────────────────────────────────────────────────

// librsync_signature generates a serialized signature from a complete file
// buffer. The caller must librsync_free(*out_ptr).
//
//export librsync_signature
func librsync_signature(
	inputPtr *C.uint8_t, inputLen C.size_t,
	blockLen, strongLen, sigType C.uint32_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	result, err := adapter.SignatureBytes(
		cInput(inputPtr, inputLen),
		uint32(blockLen), uint32(strongLen),
		librsync.MagicNumber(sigType),
	)
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_delta computes a delta from serialized signature bytes and a new
// file buffer. The caller must librsync_free(*out_ptr).
//
//export librsync_delta
func librsync_delta(
	sigPtr *C.uint8_t, sigLen C.size_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	sig, err := adapter.ParseSignature(cInput(sigPtr, sigLen))
	if err != nil {
		return errCorrupt
	}
	result, err := adapter.DeltaBytes(sig, cInput(inputPtr, inputLen))
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_patch applies a delta to a complete base file buffer.
// The caller must librsync_free(*out_ptr).
//
//export librsync_patch
func librsync_patch(
	basePtr *C.uint8_t, baseLen C.size_t,
	deltaPtr *C.uint8_t, deltaLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	result, err := adapter.PatchBytes(
		cInput(basePtr, baseLen),
		cInput(deltaPtr, deltaLen),
	)
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// ── Parsed Signature Handle ───────────────────────────────────────────────────

// librsync_sig_parse parses serialized signature bytes into an in-memory
// structure. Returns a handle > 0 on success, 0 on failure.
//
//export librsync_sig_parse
func librsync_sig_parse(sigPtr *C.uint8_t, sigLen C.size_t) C.intptr_t {
	sig, err := adapter.ParseSignature(cInput(sigPtr, sigLen))
	if err != nil {
		return 0
	}
	return storeHandle(sig)
}

// librsync_sig_free frees a parsed signature handle.
//
//export librsync_sig_free
func librsync_sig_free(handle C.intptr_t) {
	dropHandle(handle)
}

// ── Streaming Signature ───────────────────────────────────────────────────────

// librsync_signature_new creates a streaming signature session.
// Returns a handle > 0 on success, 0 on failure.
//
//export librsync_signature_new
func librsync_signature_new(blockLen, strongLen, sigType C.uint32_t) C.intptr_t {
	sess, err := adapter.NewSignatureSession(
		uint32(blockLen), uint32(strongLen),
		librsync.MagicNumber(sigType),
	)
	if err != nil {
		return 0
	}
	return storeHandle(sess)
}

// librsync_signature_feed processes a chunk of input.
// *out_ptr/*out_len receive any output produced; may be NULL/0 if the internal
// buffer has not flushed yet. Caller must librsync_free(*out_ptr) if *out_len > 0.
//
//export librsync_signature_feed
func librsync_signature_feed(
	handle C.intptr_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	sess, ok := loadHandle(handle).(*adapter.SignatureSession)
	if !ok {
		return errArgs
	}
	result, err := sess.Feed(cInput(inputPtr, inputLen))
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_signature_end finalizes the session and returns any remaining output.
// Always invalidates the handle — do NOT call librsync_signature_free after this.
//
//export librsync_signature_end
func librsync_signature_end(
	handle C.intptr_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	sess, ok := loadHandle(handle).(*adapter.SignatureSession)
	dropHandle(handle)
	if !ok {
		return errArgs
	}
	result, err := sess.End()
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_signature_free abandons the session without finalizing.
//
//export librsync_signature_free
func librsync_signature_free(handle C.intptr_t) {
	dropHandle(handle)
}

// ── Streaming Delta ───────────────────────────────────────────────────────────

// librsync_delta_new creates a streaming delta session from a parsed signature.
// Returns a handle > 0 on success, 0 on failure.
//
//export librsync_delta_new
func librsync_delta_new(sigHandle C.intptr_t) C.intptr_t {
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

// librsync_delta_feed processes a chunk of the new file.
// *out_ptr/*out_len may be NULL/0 if the literal buffer has not yet flushed.
//
//export librsync_delta_feed
func librsync_delta_feed(
	handle C.intptr_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	sess, ok := loadHandle(handle).(*adapter.DeltaSession)
	if !ok {
		return errArgs
	}
	result, err := sess.Feed(cInput(inputPtr, inputLen))
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_delta_end finalizes the session and flushes remaining output.
// Always invalidates the handle — do NOT call librsync_delta_free after this.
//
//export librsync_delta_end
func librsync_delta_end(
	handle C.intptr_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	sess, ok := loadHandle(handle).(*adapter.DeltaSession)
	dropHandle(handle)
	if !ok {
		return errArgs
	}
	result, err := sess.End()
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_delta_free abandons the session without finalizing.
//
//export librsync_delta_free
func librsync_delta_free(handle C.intptr_t) {
	dropHandle(handle)
}

// ── Streaming Patch ───────────────────────────────────────────────────────────

// patchSession wraps a PatchSession plus optional resources owned by Go.
// For librsync_patch_new (NativeCallable path): all optional fields are zero.
// For librsync_patch_new_buf (safe path): cData is non-nil and freed on teardown.
// For librsync_patch_new_path (file path): file is non-nil and closed on teardown.
type patchSession struct {
	sess  *adapter.PatchSession
	cData unsafe.Pointer // non-nil only for buf path — freed on teardown
	cLen  int64
	file  *os.File // non-nil only for path path — closed on teardown
}

func (ps *patchSession) cleanup() {
	if ps.cData != nil {
		C.free(ps.cData)
		ps.cData = nil
	}
	if ps.file != nil {
		ps.file.Close()
		ps.file = nil
	}
}

// newCallbackReadAt wraps rs_read_seeker_t as an adapter.ReadAtFunc.
// Inlined from ffi/internal/cbridge to avoid the internal package restriction.
// Used only by librsync_patch_new (the NativeCallable / Dart-closure path).
func newCallbackReadAt(rs *C.rs_read_seeker_t) adapter.ReadAtFunc {
	return func(offset int64, buf []byte) (int, error) {
		if len(buf) == 0 {
			return 0, nil
		}
		var bytesRead C.size_t
		ret := C.call_read_at(
			rs,
			C.int64_t(offset),
			(*C.uint8_t)(unsafe.Pointer(&buf[0])),
			C.size_t(len(buf)),
			&bytesRead,
		)
		n := int(bytesRead)
		if ret != 0 {
			return n, fmt.Errorf("librsync: read_at callback returned error %d", ret)
		}
		if n == 0 {
			return 0, io.EOF
		}
		return n, nil
	}
}

// newBufReadAt returns a ReadAtFunc that reads from a C-heap buffer.
// The closure captures only a plain pointer and an int — no Dart objects,
// no GC interaction — so it is safe to call from any OS thread.
func newBufReadAt(data unsafe.Pointer, dataLen int64) adapter.ReadAtFunc {
	return func(offset int64, buf []byte) (int, error) {
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
}

// librsync_patch_new creates a streaming patch session using a Dart-provided
// NativeCallable as the base-file readAt.  The rs_read_seeker_t struct and its
// NativeCallable must remain valid until librsync_patch_end or
// librsync_patch_free returns.  Returns a handle > 0 on success, 0 on failure.
//
// NOTE: NativeCallable.isolateLocal is only safe when called from the Dart
// isolate thread.  Use librsync_patch_new_buf for thread-safe operation.
//
//export librsync_patch_new
func librsync_patch_new(rs *C.rs_read_seeker_t) C.intptr_t {
	if rs == nil || rs.read_at == nil {
		return 0
	}
	sess := adapter.NewPatchSession(newCallbackReadAt(rs))
	return storeHandle(&patchSession{sess: sess})
}

// librsync_patch_new_buf creates a streaming patch session backed by a
// C-heap buffer.  The readAt closure reads directly from C memory — no Dart
// callback is invoked — so it is safe to call from any OS thread.
//
// Ownership transfer: Go takes ownership of dataPtr on success (return > 0)
// and will free it when the session is freed.  On failure (return 0) the
// caller must free dataPtr.
//
//export librsync_patch_new_buf
func librsync_patch_new_buf(dataPtr *C.uint8_t, dataLen C.size_t) C.intptr_t {
	cData := unsafe.Pointer(dataPtr)
	cLen := int64(dataLen)
	sess := adapter.NewPatchSession(newBufReadAt(cData, cLen))
	return storeHandle(&patchSession{sess: sess, cData: cData, cLen: cLen})
}

// librsync_patch_new_path creates a streaming patch session backed by a file
// opened from [path].  Go opens the file, holds it for the session lifetime,
// and closes it when the session is freed or ended.  os.File.ReadAt uses
// pread(2) on POSIX and overlapped I/O on Windows — both are thread-safe and
// position-independent, so no Dart callbacks are involved.
// Returns a handle > 0 on success, 0 on failure (file not found, no permission, etc.)
//
//export librsync_patch_new_path
func librsync_patch_new_path(path *C.char) C.intptr_t {
	f, err := os.Open(C.GoString(path))
	if err != nil {
		return 0
	}
	readAt := func(offset int64, buf []byte) (int, error) {
		return f.ReadAt(buf, offset)
	}
	sess := adapter.NewPatchSession(readAt)
	return storeHandle(&patchSession{sess: sess, file: f})
}

// librsync_patch_feed sends a chunk of the delta stream to the patch goroutine
// and returns whatever output has been produced so far. *out_ptr/*out_len may
// be NULL/0 if no output is ready yet. Caller must librsync_free(*out_ptr) if
// *out_len > 0. On error the handle is valid only for librsync_patch_free.
//
//export librsync_patch_feed
func librsync_patch_feed(
	handle C.intptr_t,
	deltaPtr *C.uint8_t, deltaLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	ps, ok := loadHandle(handle).(*patchSession)
	if !ok {
		return errArgs
	}
	result, err := ps.sess.Feed(cInput(deltaPtr, deltaLen))
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_patch_end applies the buffered delta to the base file and returns
// the reconstructed output. Always invalidates the handle.
// Caller must librsync_free(*out_ptr) if *out_len > 0.
//
//export librsync_patch_end
func librsync_patch_end(
	handle C.intptr_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	ps, ok := loadHandle(handle).(*patchSession)
	dropHandle(handle)
	if !ok {
		return errArgs
	}
	defer ps.cleanup()
	result, err := ps.sess.End()
	if err != nil {
		return errCorrupt
	}
	setOutput(outPtr, outLen, result)
	return errOK
}

// librsync_patch_free abandons the session without applying the patch.
// Blocks briefly to drain the patch goroutine cleanly.
//
//export librsync_patch_free
func librsync_patch_free(handle C.intptr_t) {
	ps, ok := loadHandle(handle).(*patchSession)
	if ok {
		ps.sess.Close()
		ps.cleanup()
	}
	dropHandle(handle)
}
