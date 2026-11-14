# Initial public export review — 2026-11-14

The public repository starts from a new source snapshot. Original private Git objects, branches and tags are not included. The private working repository and its history remain separate.

## Checks performed

- Gitleaks scans of the original reachable Git history and the exported source, with secret values redacted in reports.
- Additional searches for known operational credentials, review codes, personal contact details and private-key material.
- Manual review of scanner findings in production files, build configuration and third-party test fixtures.
- GitHub accessibility checks for all twelve pinned submodule repositories and commits.
- File-size checks against GitHub's normal 100 MB single-file limit, local JSON parsing, shell syntax and documentation/link checks.

## Export changes

Internal deployment notes, review-account documents, signing fixtures and generated artifacts were excluded. Build examples require developer-owned credentials. Inherited Google/Foursquare credentials were removed from legacy link helpers; when those helpers have no credentials, they share the original URL. Original code copyright headers and dependency licenses remain.

The raw scanner still recognises public cryptographic test vectors, test-only PKCS#12 files, PEM delimiter parsers, SQLite API macros, hashes and ordinary identifiers. These were reviewed as fixtures or syntax, rather than production credentials. Test material remains in its upstream location; it must never be used for production signing or authentication. No broad scanner allowlist was added to hide these matches.

This is a source hygiene review, not a penetration test or a guarantee that no security issues exist. No fresh full distribution build was performed for this public export. The private release build passed before the documentation/configuration and legacy-link cleanup changes. See SECURITY.md for private reporting.
