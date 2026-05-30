# Encrypted-PDF corruption detection — Bug #64 Phase 4 measurement (2026-05-29)

Fixtures: qpdf-synthesized from `alice_in_wonderland_illustrated.pdf` (an
**image-heavy** PDF — most bytes are DCTDecode image streams, not FlateDecode
content streams). 100 trials/mode/fixture, seed 42. Binary at HEAD 6e0bcaefe.

## Detection rates (detected / 100)

| Handler            | sniper | bolter | shotgun |
|--------------------|--------|--------|---------|
| V2/R3 RC4-128      | 0      | 0      | 0       |
| V4/R4 AES-128      | 0      | 1      | 0       |
| V5/R6 AES-256      | 4      | 3      | 4       |

**BEFORE (pre-#64, commit 73cc07919): 0 across all 9 cells, by construction** —
the residual sweep did `skipped_encrypted++; continue` for every stream in an
encrypted PDF, so nothing encrypted was ever byte-validated.

## Interpretation (honest)

The lift is real but small *on this fixture*, and the reason is the fixture,
not the fix:

1. Bug #64 makes **FlateDecode content streams** decrypt-then-inflate. A bit
   flip inside such a stream's ciphertext is reliably caught (AES-CBC
   avalanche breaks the subsequent inflate). The unit tests prove this on the
   clean fixtures (validated > 0, skipped_encrypted == 0).
2. But `alice_in_wonderland_illustrated.pdf` is DCTDecode-image-dominated. The
   FlateDecode content streams are a tiny fraction of its 1.7 MB, so random
   single-bit/4 KB corruption rarely lands in one. Hence 0-4%.
3. The bulk — encrypted **image (DCTDecode) and font streams** — is still
   skipped, because `pdf_image_validator` / `pdf_font_validator` bail out
   entirely on encrypted PDFs (they call the V1/2/4 `tryEmptyPassword`, which
   does succeed for V1/2/4 but they only deep-validate the *decompressed
   image*, and for V5 it returns success=false so they skip). A byte flipped
   in an encrypted image stream is invisible to validate today.

## Conclusion

Bug #64 closed the residual-FlateDecode-sweep gap (the right first step), but
the dominant encrypted-PDF detection lift requires **extending decryption into
the image and font deep validators** (the next work item). The image-heavy
benchmark here understates a content-stream-heavy PDF, where the FlateDecode
sweep alone would show a much larger lift; a future re-measure should add a
text/vector-heavy encrypted fixture for a fairer number.

TSVs in this directory are the raw per-trial records (seed 42).
