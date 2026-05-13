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
	"io"
	"unsafe"

	"github.com/gurupras/flutter-librsync/go/librsync"
)

func main() {}

// ── Conversion helpers (shared by every export below) ────────────────────────

// cInput wraps a C pointer+length as a Go byte slice without copying.
func cInput(ptr *C.uint8_t, n C.size_t) []byte {
	if n == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(ptr)), int(n))
}

// boolToInt32 converts a Go bool into the 1/0 int32 the C ABI expects.
func boolToInt32(b bool) C.int32_t {
	if b {
		return 1
	}
	return 0
}

// setOutput copies data to a malloc'd C buffer and writes (ptr, len) into
// caller output parameters.  Caller must free via librsync_free.
func setOutput(outPtr **C.uint8_t, outLen *C.size_t, data []byte) {
	if len(data) == 0 {
		*outPtr = nil
		*outLen = 0
		return
	}
	*outPtr = (*C.uint8_t)(C.CBytes(data))
	*outLen = C.size_t(len(data))
}

// callbackReadAt wraps a C rs_read_seeker_t into a Go ReadAtFunc.  Used
// only by the librsync_patch_new path (Dart NativeCallable).
func callbackReadAt(rs *C.rs_read_seeker_t) librsync.ReadAtFunc {
	return func(offset int64, buf []byte) (int, error) {
		if len(buf) == 0 {
			return 0, nil
		}
		var bytesRead C.size_t
		ret := C.call_read_at(rs, C.int64_t(offset),
			(*C.uint8_t)(unsafe.Pointer(&buf[0])),
			C.size_t(len(buf)), &bytesRead)
		n := int(bytesRead)
		if ret != 0 {
			return n, librsync.ReadAtError(int32(ret))
		}
		if n == 0 {
			return 0, io.EOF
		}
		return n, nil
	}
}

// cFreeWrapper adapts C.free to the func(unsafe.Pointer) signature librsync
// requires for buffer ownership transfer.
func cFreeWrapper(p unsafe.Pointer) { C.free(p) }

// ── Error codes ──────────────────────────────────────────────────────────────

//export librsync_strerror
func librsync_strerror(code C.int32_t) *C.char {
	msg := librsync.Strerror(int32(code))
	if msg == "" {
		return nil
	}
	return C.CString(msg)
}

//export librsync_free
func librsync_free(ptr unsafe.Pointer) { C.free(ptr) }

// ── Batch API ────────────────────────────────────────────────────────────────

//export librsync_signature
func librsync_signature(
	inputPtr *C.uint8_t, inputLen C.size_t,
	blockLen, strongLen, sigType C.uint32_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.Signature(cInput(inputPtr, inputLen),
		uint32(blockLen), uint32(strongLen), uint32(sigType))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_delta
func librsync_delta(
	sigPtr *C.uint8_t, sigLen C.size_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.Delta(cInput(sigPtr, sigLen), cInput(inputPtr, inputLen))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_patch
func librsync_patch(
	basePtr *C.uint8_t, baseLen C.size_t,
	deltaPtr *C.uint8_t, deltaLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.Patch(cInput(basePtr, baseLen), cInput(deltaPtr, deltaLen))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

// ── Parsed-signature handle ──────────────────────────────────────────────────

//export librsync_sig_parse
func librsync_sig_parse(sigPtr *C.uint8_t, sigLen C.size_t) C.intptr_t {
	return C.intptr_t(librsync.SigParse(cInput(sigPtr, sigLen)))
}

//export librsync_sig_free
func librsync_sig_free(handle C.intptr_t) { librsync.SigFree(librsync.Handle(handle)) }

// ── Streaming signature ──────────────────────────────────────────────────────

//export librsync_signature_new
func librsync_signature_new(blockLen, strongLen, sigType C.uint32_t) C.intptr_t {
	return C.intptr_t(librsync.SignatureNew(uint32(blockLen), uint32(strongLen), uint32(sigType)))
}

//export librsync_signature_feed
func librsync_signature_feed(
	handle C.intptr_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.SignatureFeed(librsync.Handle(handle), cInput(inputPtr, inputLen))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_signature_end
func librsync_signature_end(
	handle C.intptr_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.SignatureEnd(librsync.Handle(handle))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_signature_free
func librsync_signature_free(handle C.intptr_t) { librsync.SignatureFree(librsync.Handle(handle)) }

//export librsync_signature_feed_into
func librsync_signature_feed_into(
	handle C.intptr_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	dstPtr *C.uint8_t, dstLen C.size_t,
	bytesWritten *C.size_t, morePending *C.int32_t,
) C.int32_t {
	n, more, status := librsync.SignatureFeedInto(librsync.Handle(handle),
		cInput(inputPtr, inputLen), cInput(dstPtr, dstLen))
	if status == librsync.ErrOK {
		*bytesWritten = C.size_t(n)
		*morePending = boolToInt32(more)
	}
	return C.int32_t(status)
}

//export librsync_signature_end_into
func librsync_signature_end_into(
	handle C.intptr_t,
	dstPtr *C.uint8_t, dstLen C.size_t,
	bytesWritten *C.size_t, morePending *C.int32_t,
) C.int32_t {
	n, more, status := librsync.SignatureEndInto(librsync.Handle(handle), cInput(dstPtr, dstLen))
	if status == librsync.ErrOK {
		*bytesWritten = C.size_t(n)
		*morePending = boolToInt32(more)
	}
	return C.int32_t(status)
}

// ── Streaming delta ──────────────────────────────────────────────────────────

//export librsync_delta_new
func librsync_delta_new(sigHandle C.intptr_t) C.intptr_t {
	return C.intptr_t(librsync.DeltaNew(librsync.Handle(sigHandle)))
}

//export librsync_delta_feed
func librsync_delta_feed(
	handle C.intptr_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.DeltaFeed(librsync.Handle(handle), cInput(inputPtr, inputLen))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_delta_end
func librsync_delta_end(
	handle C.intptr_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.DeltaEnd(librsync.Handle(handle))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_delta_feed_into
func librsync_delta_feed_into(
	handle C.intptr_t,
	inputPtr *C.uint8_t, inputLen C.size_t,
	dstPtr *C.uint8_t, dstLen C.size_t,
	bytesWritten *C.size_t, morePending *C.int32_t,
) C.int32_t {
	n, more, status := librsync.DeltaFeedInto(librsync.Handle(handle),
		cInput(inputPtr, inputLen), cInput(dstPtr, dstLen))
	if status == librsync.ErrOK {
		*bytesWritten = C.size_t(n)
		*morePending = boolToInt32(more)
	}
	return C.int32_t(status)
}

//export librsync_delta_end_into
func librsync_delta_end_into(
	handle C.intptr_t,
	dstPtr *C.uint8_t, dstLen C.size_t,
	bytesWritten *C.size_t, morePending *C.int32_t,
) C.int32_t {
	n, more, status := librsync.DeltaEndInto(librsync.Handle(handle), cInput(dstPtr, dstLen))
	if status == librsync.ErrOK {
		*bytesWritten = C.size_t(n)
		*morePending = boolToInt32(more)
	}
	return C.int32_t(status)
}

//export librsync_delta_free
func librsync_delta_free(handle C.intptr_t) { librsync.DeltaFree(librsync.Handle(handle)) }

// ── Streaming patch ──────────────────────────────────────────────────────────

//export librsync_patch_new
func librsync_patch_new(rs *C.rs_read_seeker_t) C.intptr_t {
	if rs == nil || rs.read_at == nil {
		return 0
	}
	return C.intptr_t(librsync.PatchNew(callbackReadAt(rs)))
}

//export librsync_patch_new_buf
func librsync_patch_new_buf(dataPtr *C.uint8_t, dataLen C.size_t) C.intptr_t {
	return C.intptr_t(librsync.PatchNewBuf(unsafe.Pointer(dataPtr), int64(dataLen), cFreeWrapper))
}

//export librsync_patch_new_path
func librsync_patch_new_path(path *C.char) C.intptr_t {
	return C.intptr_t(librsync.PatchNewPath(C.GoString(path)))
}

//export librsync_patch_feed
func librsync_patch_feed(
	handle C.intptr_t,
	deltaPtr *C.uint8_t, deltaLen C.size_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.PatchFeed(librsync.Handle(handle), cInput(deltaPtr, deltaLen))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_patch_end
func librsync_patch_end(
	handle C.intptr_t,
	outPtr **C.uint8_t, outLen *C.size_t,
) C.int32_t {
	out, status := librsync.PatchEnd(librsync.Handle(handle))
	if status == librsync.ErrOK {
		setOutput(outPtr, outLen, out)
	}
	return C.int32_t(status)
}

//export librsync_patch_feed_into
func librsync_patch_feed_into(
	handle C.intptr_t,
	deltaPtr *C.uint8_t, deltaLen C.size_t,
	dstPtr *C.uint8_t, dstLen C.size_t,
	bytesWritten *C.size_t, morePending *C.int32_t,
) C.int32_t {
	n, more, status := librsync.PatchFeedInto(librsync.Handle(handle),
		cInput(deltaPtr, deltaLen), cInput(dstPtr, dstLen))
	if status == librsync.ErrOK {
		*bytesWritten = C.size_t(n)
		*morePending = boolToInt32(more)
	}
	return C.int32_t(status)
}

//export librsync_patch_end_into
func librsync_patch_end_into(
	handle C.intptr_t,
	dstPtr *C.uint8_t, dstLen C.size_t,
	bytesWritten *C.size_t, morePending *C.int32_t,
) C.int32_t {
	n, more, status := librsync.PatchEndInto(librsync.Handle(handle), cInput(dstPtr, dstLen))
	if status == librsync.ErrOK {
		*bytesWritten = C.size_t(n)
		*morePending = boolToInt32(more)
	}
	return C.int32_t(status)
}

//export librsync_patch_free
func librsync_patch_free(handle C.intptr_t) { librsync.PatchFree(librsync.Handle(handle)) }
