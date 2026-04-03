//go:build js && wasm

// Package main exports librsync operations to JavaScript / Flutter Web via
// WebAssembly.  The API intentionally mirrors the streaming pattern of the
// native CGO layer so that the Dart web implementation can use the same
// conceptual interface.
//
// Usage from JS/Dart:
//
//	const sig = librsync.newSignature(blockLen, strongLen, sigType);
//	sig.write(uint8ArrayChunk);       // feed input in chunks
//	const sigBytes = sig.finish();    // flush & return Uint8Array
//
//	const delta = librsync.newDelta(sigBytes, bufSize);
//	delta.write(uint8ArrayChunk);
//	const deltaBytes = delta.finish();
//
//	const patch = librsync.newPatch(baseUint8Array);
//	patch.write(deltaChunk);
//	const patchedBytes = patch.finish();

package main

import (
	"bytes"
	"fmt"
	"syscall/js"

	librsync "github.com/balena-os/librsync-go"
)

func main() {
	obj := js.Global().Get("Object").New()

	obj.Set("newSignature", js.FuncOf(jsNewSignature))
	obj.Set("newDelta", js.FuncOf(jsNewDelta))
	obj.Set("newPatch", js.FuncOf(jsNewPatch))
	obj.Set("BLAKE2_SIG_MAGIC", int(librsync.BLAKE2_SIG_MAGIC))
	obj.Set("MD4_SIG_MAGIC", int(librsync.MD4_SIG_MAGIC))

	js.Global().Set("librsync", obj)

	// Keep the WASM module alive.
	select {}
}

// ─── Signature ────────────────────────────────────────────────────────────────

// jsNewSignature creates a streaming signature job.
//
// JS: librsync.newSignature(blockLen: number, strongLen: number, sigType: number)
//     → { write(Uint8Array), finish() → Uint8Array }
func jsNewSignature(_ js.Value, args []js.Value) any {
	if len(args) < 3 {
		return jsError("newSignature requires (blockLen, strongLen, sigType)")
	}
	blockLen := uint32(args[0].Int())
	strongLen := uint32(args[1].Int())
	sigType := librsync.MagicNumber(args[2].Int())

	output := new(bytes.Buffer)
	sig, err := librsync.NewSignature(sigType, blockLen, strongLen, output)
	if err != nil {
		return jsError(err.Error())
	}

	obj := js.Global().Get("Object").New()

	obj.Set("write", js.FuncOf(func(_ js.Value, a []js.Value) any {
		if len(a) < 1 {
			return jsError("write requires a Uint8Array argument")
		}
		data := jsBytes(a[0])
		if err := sig.Digest(data); err != nil {
			return jsError(err.Error())
		}
		return js.Null()
	}))

	obj.Set("finish", js.FuncOf(func(_ js.Value, _ []js.Value) any {
		sig.End()
		return toUint8Array(output.Bytes())
	}))

	return obj
}

// ─── Delta ─────────────────────────────────────────────────────────────────────

// jsNewDelta creates a streaming delta job.
//
// JS: librsync.newDelta(sigBytes: Uint8Array, bufSize?: number)
//     → { write(Uint8Array), finish() → Uint8Array }
func jsNewDelta(_ js.Value, args []js.Value) any {
	if len(args) < 1 {
		return jsError("newDelta requires (sigBytes)")
	}
	sigBytes := jsBytes(args[0])

	sig, err := librsync.ReadSignature(bytes.NewReader(sigBytes))
	if err != nil {
		return jsError(fmt.Sprintf("read signature: %v", err))
	}

	bufSize := 0
	if len(args) >= 2 && args[1].Type() == js.TypeNumber {
		bufSize = args[1].Int()
	}

	output := new(bytes.Buffer)
	delta, err := librsync.NewDelta(sig, output, bufSize)
	if err != nil {
		return jsError(err.Error())
	}

	obj := js.Global().Get("Object").New()

	obj.Set("write", js.FuncOf(func(_ js.Value, a []js.Value) any {
		if len(a) < 1 {
			return jsError("write requires a Uint8Array argument")
		}
		data := jsBytes(a[0])
		// Drain output after each Digest call so it doesn't grow unboundedly.
		prevLen := output.Len()
		if err := delta.Digest(data); err != nil {
			return jsError(err.Error())
		}
		if output.Len() > prevLen {
			// Return any newly produced delta bytes so callers can stream them out.
			produced := output.Bytes()[prevLen:]
			return toUint8Array(produced)
		}
		return js.Null()
	}))

	obj.Set("finish", js.FuncOf(func(_ js.Value, _ []js.Value) any {
		if err := delta.End(); err != nil {
			return jsError(err.Error())
		}
		return toUint8Array(output.Bytes())
	}))

	return obj
}

// ─── Patch ─────────────────────────────────────────────────────────────────────

// jsNewPatch creates a streaming patch job.
//
// JS: librsync.newPatch(baseBytes: Uint8Array)
//     → { write(Uint8Array), finish() → Uint8Array }
func jsNewPatch(_ js.Value, args []js.Value) any {
	if len(args) < 1 {
		return jsError("newPatch requires (baseBytes: Uint8Array)")
	}
	baseBytes := jsBytes(args[0])
	base := bytes.NewReader(baseBytes)

	deltaInput := new(bytes.Buffer)
	output := new(bytes.Buffer)

	obj := js.Global().Get("Object").New()

	obj.Set("write", js.FuncOf(func(_ js.Value, a []js.Value) any {
		if len(a) < 1 {
			return jsError("write requires a Uint8Array argument")
		}
		deltaInput.Write(jsBytes(a[0]))
		return js.Null()
	}))

	obj.Set("finish", js.FuncOf(func(_ js.Value, _ []js.Value) any {
		if err := librsync.Patch(base, deltaInput, output); err != nil {
			return jsError(err.Error())
		}
		return toUint8Array(output.Bytes())
	}))

	return obj
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func jsBytes(v js.Value) []byte {
	b := make([]byte, v.Length())
	js.CopyBytesToGo(b, v)
	return b
}

func toUint8Array(b []byte) js.Value {
	arr := js.Global().Get("Uint8Array").New(len(b))
	js.CopyBytesToJS(arr, b)
	return arr
}

func jsError(msg string) js.Value {
	return js.Global().Get("Error").New(msg)
}
