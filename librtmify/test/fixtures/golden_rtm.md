# Requirements Traceability Matrix

Input: RTMify_Requirements_Tracking_Template.xlsx
Generated: 2024-01-01T00:00:00Z

## User Needs

| ID | Statement | Source | Priority |
| --- | --- | --- | --- |
| UN-001 | This better work | Customer | high |

## Requirements Traceability

| Req ID | User Need | Statement | Test Group | Test ID | Type | Method | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **⚠** REQ-001 | UN-001 | The system SHALL work | — | — | — | — | Approved |
| **⚠** REQ-002 | — | The system SHALL NOT be broken | TG-001 | T-001 | Verification | Inspection | Draft |
| **⚠** REQ-002 | — | The system SHALL NOT be broken | TG-001 | T-002 | Validation | Demonstration | Draft |

## Tests

| Test Group | Test ID | Type | Method | Linked Req |
| --- | --- | --- | --- | --- |
| TG-001 | T-001 | Verification | Inspection | REQ-002 |
| TG-001 | T-002 | Validation | Demonstration | REQ-002 |
| TG-002 | T-003 | Verification | Test | — |
| TG-002 | T-004 | Validation | Analysis | — |

## Risk Register

| Risk ID | Description | Init. Sev | Init. Like | Init. Score | Mitigation | Linked Req | Res. Sev | Res. Like | Res. Score |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RSK-101 | Clock drift at high temp | 4 | 3 | 12 | Add external TCXO | **⚠** REQ-602 | 4 | 1 | 4 |

## Gap Summary

**3 gap(s) found.**

### Untested Requirements (1)

- REQ-001

### Orphan Requirements — no User Need (1)

- REQ-002

### Unresolved Risk Mitigations (1)

- RSK-101 → REQ-602
