# Encrypted originals

Fixtures for `PDFEncryptedReadTests`, `PDFEncryptedAppendTests` and `PDFEncryptedR6Tests`: a small unencrypted PDF
(`plain.pdf`, two pages, written by macOS Quartz, Info `/Title (Sample Title)`), encrypted by generators other than
this package so the security handler is checked against files it did not write. Every one has an owner password ("owner-only") and, except `aes128-user-password.pdf`, an
empty user password — the shape of a score's original that opens without a password but restricts what may be done
to it.

| File | Revision, method | Made with |
| --- | --- | --- |
| `rc4-40.pdf` | R2, RC4 40-bit | pypdf 6.14 |
| `rc4-128.pdf` | R3, RC4 128-bit | pypdf 6.14 |
| `rc4-128-page-string.pdf` | R3, RC4 128-bit; the page holds a string of its own | pypdf 6.14 |
| `aes128-allowed.pdf` | R4, AESV2 (AES-128), annotations allowed | CoreGraphics |
| `aes128-forbidden.pdf` | R4, AESV2, printing only (no `/P` bit 6) | CoreGraphics |
| `aes128-user-password.pdf` | R4, AESV2, user password "user-secret" | CoreGraphics |

## pypdf (RC4)

pypdf without an AES backend writes RC4 only. Run with the system Python, in a script file:

```python
from pypdf import PdfReader, PdfWriter

reader = PdfReader("plain.pdf")
for name, algorithm in (("rc4-40", "RC4-40"), ("rc4-128", "RC4-128")):
    writer = PdfWriter(clone_from=reader)
    writer.encrypt(user_password="", owner_password="owner-only", algorithm=algorithm)
    with open(f"{name}.pdf", "wb") as out:
        writer.write(out)
```

(These two are folino's `ReaderTests/Resources/encrypted-owner-only-rc4-{40,128}.pdf`, made the same way.)

`rc4-128-page-string.pdf` gives the page a string before encrypting, so a test can see that a page rewritten with the
ink keeps its own strings readable — they are decrypted on reading and must be encrypted again under the page's number:

```python
from pypdf.generic import DictionaryObject, NameObject, TextStringObject

writer = PdfWriter(clone_from=PdfReader("plain.pdf"))
writer.pages[0][NameObject("/PieceInfo")] = DictionaryObject({
    NameObject("/folino"): DictionaryObject({
        NameObject("/LastModified"): TextStringObject("D:20261116000000Z"),
        NameObject("/Private"): TextStringObject("a page's own string"),
    }),
})
writer.encrypt(user_password="", owner_password="owner-only", algorithm="RC4-128")
with open("rc4-128-page-string.pdf", "wb") as out:
    writer.write(out)
```

## CoreGraphics (AES-128)

CoreGraphics writes `/V 4 /R 4 /CFM /AESV2` when asked for a 128-bit key, and refuses 256 (`CGContext` comes back
nil), so it cannot make the AES-256 (R6) fixture. The first page of `plain.pdf` is drawn into a PDF context, so these
three have one page:

```swift
var info: [CFString: Any] = [
    kCGPDFContextOwnerPassword: "owner-only",
    kCGPDFContextEncryptionKeyLength: 128,
    kCGPDFContextAccessPermissions: permissions.rawValue,   // allowed: printing, commenting, copying; forbidden: printing
    kCGPDFContextTitle: "folino fixture",
]
// aes128-user-password.pdf only:
info[kCGPDFContextUserPassword] = "user-secret"
let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)
context.beginPDFPage(nil); context.drawPDFPage(page); context.endPDFPage(); context.closePDF()
```

## AES-256 (R6)

No generator on the machine writes AES-256 yet, so `PDFEncryptedR6Tests` encrypts `plain.pdf` itself
(`R6TestEncryption`, in the tests) and hands the result to PDFKit, which derives the key its own way: PDFKit opening it
without a password, reading its title and taking the owner password is the independent check.

## Still to add

An AES-256 (R6) original from an independent generator (qpdf), once one is available on the machine.
