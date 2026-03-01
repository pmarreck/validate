# Wave 1: Text-Based Archival Format Validators

**Date**: 2026-02-28
**Status**: Approved

## Goal

Add 6 text-based formats with real integrity mechanisms or strong structural grammar to `validate`. These complement the existing 185 formats, targeting professional archival and personal data preservation.

## Formats

### 1. BagIt (Library of Congress digital preservation standard)
- **Detection**: Directory containing `bagit.txt` at root
- **Files**: `bagit.txt`, `bag-info.txt`, `manifest-{alg}.txt`, `tagmanifest-{alg}.txt`, `data/`
- **Structural**: Verify `bagit.txt` version/encoding, manifest file exists, `data/` directory exists
- **Deep**: Hash every file listed in `manifest-{alg}.txt` (SHA-256, SHA-512, MD5), verify matches. Also verify `tagmanifest-{alg}.txt` against metadata files.
- **Architecture**: Bundle validator (like `.git`). New file: `bagit_validator.zig`
- **Corruption opacity**: transparent (full content hashing)

### 2. X12 EDI (US healthcare, supply chain, insurance — ~$4T industry)
- **Detection**: Starts with `ISA` + delimiter at position 3; ISA segment = 106 chars
- **Extensions**: `.edi`, `.x12`, `.837`, `.835`, `.834`, `.820`
- **Structural**: Verify ISA segment (106 chars), self-describing delimiters, valid segment hierarchy (ISA→GS→ST→...→SE→GE→IEA)
- **Deep**: SE01 = segment count (ST through SE inclusive), GE01 = transaction set count, IEA01 = functional group count. Cross-validate all control numbers match.
- **Architecture**: New file: `edi_validators.zig`
- **Corruption opacity**: transparent (arithmetic integrity at 3 levels)

### 3. EDIFACT (international trade EDI — UN/CEFACT standard)
- **Detection**: Starts with `UNA` (service string advice) or `UNB+`
- **Extensions**: `.edi` (shared with X12, distinguished by content), `.edifact`
- **Structural**: Verify UNB envelope, valid segment hierarchy (UNB→UNG?→UNH→...→UNT→UNE?→UNZ)
- **Deep**: UNT = segment count + reference match, UNE = message count, UNZ = group/message count
- **Architecture**: Same file as X12: `edi_validators.zig`
- **Corruption opacity**: transparent

### 4. iCalendar (RFC 5545 — everyone's calendar data)
- **Detection**: Starts with `BEGIN:VCALENDAR`
- **Extensions**: `.ics`, `.ical`
- **Structural**: Verify BEGIN/END nesting, required properties (VERSION, PRODID), valid component types (VEVENT, VTODO, VJOURNAL, VFREEBUSY, VTIMEZONE)
- **Deep**: Validate DTSTART/DTEND consistency, RRULE grammar, VTIMEZONE completeness, property value types (DATE, DATE-TIME, DURATION)
- **Architecture**: New file: `pim_validators.zig` (Personal Information Management)
- **Corruption opacity**: mixed (structural grammar, no checksums)

### 5. vCard (RFC 6350 — everyone's contact data)
- **Detection**: Starts with `BEGIN:VCARD`
- **Extensions**: `.vcf`, `.vcard`
- **Structural**: Verify BEGIN/END:VCARD envelope, VERSION property, required properties per version (FN for v4, N for v3)
- **Deep**: Validate property types, parameter syntax, base64-encoded embedded data (PHOTO), multi-valued properties
- **Architecture**: Same file: `pim_validators.zig`
- **Corruption opacity**: mixed

### 6. PEM/DER (X.509 certificates, keys — IT infrastructure)
- **Detection**: PEM starts with `-----BEGIN `; DER starts with 0x30 (ASN.1 SEQUENCE)
- **Extensions**: `.pem`, `.crt`, `.cer`, `.key`, `.csr`, `.der`
- **Structural**: PEM: verify header/footer match, valid base64 between. DER: verify ASN.1 SEQUENCE tag, consistent lengths.
- **Deep**: Parse ASN.1 TLV structure recursively, verify OID validity, check certificate fields (issuer, subject, validity dates, signature algorithm)
- **Architecture**: New file: `crypto_validators.zig`
- **Corruption opacity**: mixed (ASN.1 structural, no content checksums)

## File Organization

| New file | Formats |
|----------|---------|
| `src/core/bagit_validator.zig` | BagIt directories |
| `src/core/edi_validators.zig` | X12 EDI, EDIFACT |
| `src/core/pim_validators.zig` | iCalendar, vCard |
| `src/core/crypto_validators.zig` | PEM, DER |

## Registration Points (per format)
- `format_validation.zig`: FileFormat enum, hasValidator, detectFormat/extension, ext_has_no_magic, structural dispatch, deep dispatch
- `ffi/c_api.zig`: getFormatCategory
- 30 i18n locale files: format descriptions
- `scripts/corruption_opacity.tsv`: opacity classification

## Ground Truth Samples
- All 6 formats are text-based or have text representations → synthesizable
- BagIt: create a small bag with 2-3 payload files and SHA-256 manifest
- X12: valid 837P (healthcare claim) with correct control totals
- EDIFACT: valid INVOIC message with correct UNT/UNZ counts
- iCalendar: valid .ics with VEVENT, VTIMEZONE, RRULE
- vCard: valid v4.0 .vcf with structured name, photo, address
- PEM: valid self-signed X.509 certificate
- **Note**: All synthetic. Flag in PLAN.md for future replacement with real-world samples.
