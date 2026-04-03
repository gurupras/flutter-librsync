package main

/*
#include <stdint.h>
#include <stdlib.h>

typedef int64_t (*rs_read_fn_t)(void* ctx, uint8_t* buf, int64_t len);
typedef int64_t (*rs_seek_fn_t)(void* ctx, int64_t offset, int32_t whence);
typedef int64_t (*rs_write_fn_t)(void* ctx, const uint8_t* buf, int64_t len);

// Sequential reader (no seek; used for signature input, new-data input, delta input)
typedef struct {
    rs_read_fn_t read;
    void*        ctx;
} rs_reader_t;

// Seekable reader (used for patch base)
typedef struct {
    rs_read_fn_t read;
    rs_seek_fn_t seek;
    void*        ctx;
} rs_read_seeker_t;

// Writer (used for all outputs)
typedef struct {
    rs_write_fn_t write;
    void*         ctx;
} rs_writer_t;

// Inline helpers to call through function pointers.
// CGO does not allow calling C function pointers directly from Go,
// so we use static inline trampolines.
static inline int64_t _rs_read(rs_reader_t* r, uint8_t* buf, int64_t len) {
    return r->read(r->ctx, buf, len);
}
static inline int64_t _rs_rs_read(rs_read_seeker_t* r, uint8_t* buf, int64_t len) {
    return r->read(r->ctx, buf, len);
}
static inline int64_t _rs_seek(rs_read_seeker_t* r, int64_t offset, int32_t whence) {
    return r->seek(r->ctx, offset, whence);
}
static inline int64_t _rs_write(rs_writer_t* w, const uint8_t* buf, int64_t len) {
    return w->write(w->ctx, buf, len);
}
*/
import "C"

import (
	"fmt"
	"io"
	"unsafe"

	librsync "github.com/balena-os/librsync-go"
)

// cReader wraps rs_reader_t as an io.Reader.
type cReader struct{ r *C.rs_reader_t }

func (r *cReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	n := C._rs_read(r.r, (*C.uint8_t)(unsafe.Pointer(&p[0])), C.int64_t(len(p)))
	if n < 0 {
		return 0, fmt.Errorf("read error: %d", n)
	}
	if n == 0 {
		return 0, io.EOF
	}
	return int(n), nil
}

// cReadSeeker wraps rs_read_seeker_t as an io.ReadSeeker.
type cReadSeeker struct{ r *C.rs_read_seeker_t }

func (r *cReadSeeker) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	n := C._rs_rs_read(r.r, (*C.uint8_t)(unsafe.Pointer(&p[0])), C.int64_t(len(p)))
	if n < 0 {
		return 0, fmt.Errorf("read error: %d", n)
	}
	if n == 0 {
		return 0, io.EOF
	}
	return int(n), nil
}

func (r *cReadSeeker) Seek(offset int64, whence int) (int64, error) {
	n := C._rs_seek(r.r, C.int64_t(offset), C.int32_t(whence))
	if n < 0 {
		return 0, fmt.Errorf("seek error: %d", n)
	}
	return int64(n), nil
}

// cWriter wraps rs_writer_t as an io.Writer.
type cWriter struct{ w *C.rs_writer_t }

func (w *cWriter) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	n := C._rs_write(w.w, (*C.uint8_t)(unsafe.Pointer(&p[0])), C.int64_t(len(p)))
	if n < 0 {
		return 0, fmt.Errorf("write error: %d", n)
	}
	return int(n), nil
}

// librsync_signature generates an rsync signature.
//
// input    – sequential reader for the basis file
// output   – writer for the signature data
// blockLen – block length for checksumming (e.g. 2048)
// strongLen – strong hash length in bytes (e.g. 32 for BLAKE2)
// sigType  – magic number: BLAKE2_SIG_MAGIC (0x72730137) or MD4_SIG_MAGIC (0x72730136)
//
// Returns NULL on success, or a heap-allocated C string describing the error.
// The caller must free the returned string with librsync_free_string.
//
//export librsync_signature
func librsync_signature(
	input *C.rs_reader_t,
	output *C.rs_writer_t,
	blockLen, strongLen, sigType C.uint32_t,
) *C.char {
	_, err := librsync.Signature(
		&cReader{r: input},
		&cWriter{w: output},
		uint32(blockLen),
		uint32(strongLen),
		librsync.MagicNumber(sigType),
	)
	if err != nil {
		return C.CString(err.Error())
	}
	return nil
}

// librsync_delta generates a delta between a signature and new file data.
//
// sigInput – sequential reader for the signature produced by librsync_signature
// newData  – sequential reader for the new (modified) file
// output   – writer for the delta data
//
// Returns NULL on success, or a heap-allocated error string (free with librsync_free_string).
//
//export librsync_delta
func librsync_delta(
	sigInput *C.rs_reader_t,
	newData *C.rs_reader_t,
	output *C.rs_writer_t,
) *C.char {
	sig, err := librsync.ReadSignature(&cReader{r: sigInput})
	if err != nil {
		return C.CString(fmt.Sprintf("read signature: %v", err))
	}
	if err := librsync.Delta(sig, &cReader{r: newData}, &cWriter{w: output}); err != nil {
		return C.CString(fmt.Sprintf("delta: %v", err))
	}
	return nil
}

// librsync_patch reconstructs a new file by applying a delta to a base file.
//
// base   – seekable reader for the basis file (must support random access)
// delta  – sequential reader for the delta produced by librsync_delta
// output – writer for the reconstructed file
//
// Returns NULL on success, or a heap-allocated error string (free with librsync_free_string).
//
//export librsync_patch
func librsync_patch(
	base *C.rs_read_seeker_t,
	delta *C.rs_reader_t,
	output *C.rs_writer_t,
) *C.char {
	if err := librsync.Patch(&cReadSeeker{r: base}, &cReader{r: delta}, &cWriter{w: output}); err != nil {
		return C.CString(fmt.Sprintf("patch: %v", err))
	}
	return nil
}

// librsync_free_string frees a C string returned by any librsync_* function.
//
//export librsync_free_string
func librsync_free_string(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// librsync_blake2_sig_magic returns the BLAKE2 signature magic number.
//
//export librsync_blake2_sig_magic
func librsync_blake2_sig_magic() C.uint32_t {
	return C.uint32_t(librsync.BLAKE2_SIG_MAGIC)
}

// librsync_md4_sig_magic returns the MD4 signature magic number (deprecated).
//
//export librsync_md4_sig_magic
func librsync_md4_sig_magic() C.uint32_t {
	return C.uint32_t(librsync.MD4_SIG_MAGIC)
}

func main() {}
