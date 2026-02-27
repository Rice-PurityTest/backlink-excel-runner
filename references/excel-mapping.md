# Excel Mapping

Input is configurable per file/sheet.

Minimum required logical fields:
- `url`
- `method`
- `note` (optional but recommended)
- `status`
- `landing`

Example mapping (current table):
- A: url
- B: method
- C: note
- D: status
- E: landing

Validation:
- URL must match `^https?://`
- Missing mapping => stop run
- Missing sheet => stop run
