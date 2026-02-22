#!/usr/bin/env python3
"""
X12 Healthcare Claim Parser  –  Viewer Edition
===============================================
This script is called automatically by the Claim Viewer web application
every time a user uploads a raw X12 EDI file.  The user never needs to
run it manually – the web app does it behind the scenes.

What it does
------------
1. Reads a raw X12 EDI file (the industry-standard format used by
   hospitals, insurance companies, and clearinghouses).
2. Walks through every segment in the file and extracts the fields
   that matter for display: patient info, payer, provider, service
   lines, diagnosis codes, etc.
3. Writes a clean JSON file that the web app stores in PostgreSQL
   and renders on screen.

Input  → any X12 837 file  (.txt / .edi / .x12 / .837)
Output → a JSON array of "sections" that the Claim Viewer understands

NOTE ON DEPENDENCIES
--------------------
This parser reads X12 files directly – it does NOT use the pyx12
library.  Direct parsing is simpler, faster, and works with any file
encoding or X12 dialect without external dependencies.

Command-line usage (for testing; the web app calls this automatically):
    python3 parser_for_viewer.py  <input_file>  [output_file]
"""

import json
import sys
import os


# ─────────────────────────────────────────────────────────────────────────────
# FILE READING
# ─────────────────────────────────────────────────────────────────────────────

def read_x12_segments(filepath):
    """
    Read an X12 file and return (segments, ele_sep, seg_term).

    X12 files are self-describing: the ISA segment tells us which character
    is the element separator and which is the segment terminator.  We read
    those from ISA, then split the whole file on those characters.

    Some X12 exports omit the ISA/GS envelope and start directly with the
    ST segment.  We detect both cases automatically.

    This approach:
    - Works with any segment terminator (~ is common but not required)
    - Works with any element separator (* is common but not required)
    - Handles UTF-8, latin-1, Windows-1252, and BOM-prefixed files
    - Handles files with or without an ISA interchange envelope
    - Has no external library dependencies
    """
    # ── Step 1: read raw bytes ────────────────────────────────────────────────
    try:
        with open(filepath, 'rb') as f:
            raw_bytes = f.read()
    except Exception as e:
        raise RuntimeError(f"Cannot read file '{filepath}': {e}")

    # Strip UTF-8 BOM if present (some editors add this automatically)
    if raw_bytes.startswith(b'\xef\xbb\xbf'):
        raw_bytes = raw_bytes[3:]

    # Decode to a string.  We use latin-1 as the final fallback because it
    # maps every byte value 0-255 to a character – it never raises an error.
    content = None
    for encoding in ('utf-8', 'cp1252', 'latin-1'):
        try:
            content = raw_bytes.decode(encoding)
            break
        except (UnicodeDecodeError, LookupError):
            continue

    import re

    # ── Step 2: find the start of the X12 data and detect delimiters ─────────

    isa_match = re.search(r'ISA(.)', content, re.IGNORECASE)

    if isa_match:
        # Standard X12 file: has a full ISA interchange envelope.
        parse_start = isa_match.start()
        ele_sep = isa_match.group(1)   # character right after "ISA"

        # Find the segment terminator by counting exactly 16 element separators.
        # ISA always has 16 data elements; the seg_term is the char right after
        # ISA16 (the component separator, e.g. ":").
        #
        # Using split(ele_sep, 17):
        #   parts[0]  = "ISA"
        #   parts[1..15] = ISA01–ISA15
        #   parts[16] = "<ISA16><seg_term><rest_of_file>"
        parts = content[parse_start:].split(ele_sep, 17)
        if len(parts) < 17:
            raise RuntimeError(
                "ISA segment does not have 16 element separators.  "
                "The file may be malformed."
            )
        after_isa16 = parts[16]
        if len(after_isa16) < 2:
            raise RuntimeError(
                "Cannot determine segment terminator from ISA16.  "
                "The file may be truncated."
            )
        seg_term = after_isa16[1]   # almost always ~

    else:
        # No ISA envelope: file starts directly with the ST transaction set.
        # Detect ele_sep from the character immediately after "ST".
        # We require that "ST" is not preceded by another alphanumeric character
        # so we don't accidentally match "FIRST" or "BEST" inside a data value.
        st_match = re.search(r'(?<![A-Za-z0-9])ST([^A-Za-z0-9\s])', content)
        if not st_match:
            raise RuntimeError(
                "Not a valid X12 file: no ISA or ST segment found.  "
                "Make sure you are uploading an 837 claim file."
            )
        parse_start = st_match.start()
        ele_sep = st_match.group(1)   # e.g. "*"

        # Find the segment terminator by scanning forward from the ST segment.
        # Skip alphanumeric characters and ele_sep characters; the first other
        # character we encounter is the segment terminator (usually "~").
        seg_term = '~'   # sensible default
        for ch in content[parse_start:]:
            if not (ch.isalnum() or ch == ele_sep or ch in (' ', '\t', ':', '-')):
                seg_term = ch
                break

    # ── Step 3: split the content into segments ───────────────────────────────
    segments = []
    for raw_seg in content[parse_start:].split(seg_term):
        seg = raw_seg.strip()
        if not seg:
            continue
        elements = seg.split(ele_sep)
        seg_id = elements[0].strip().upper()
        if seg_id:
            segments.append((seg_id, elements))

    return segments, ele_sep, seg_term


# ─────────────────────────────────────────────────────────────────────────────
# VALUE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def parse_date(date_str):
    """
    X12 stores dates as YYYYMMDD (e.g. "20230415").
    Convert to the familiar ISO format YYYY-MM-DD (e.g. "2023-04-15").
    """
    if not date_str or len(date_str) != 8:
        return date_str
    try:
        return f"{date_str[0:4]}-{date_str[4:6]}-{date_str[6:8]}"
    except Exception:
        return date_str


def parse_time(time_str):
    """
    X12 stores times as HHMM (e.g. "1430").
    Convert to HH:MM (e.g. "14:30").
    """
    if not time_str or len(time_str) < 4:
        return time_str
    try:
        return f"{time_str[0:2]}:{time_str[2:4]}"
    except Exception:
        return time_str


def clean_value(value):
    """
    Remove tilde (~), extra whitespace, and segment terminators that
    sometimes appear at the end of X12 element values.
    """
    if not value:
        return ""
    return str(value).replace('~', '').strip()


def clean_code(code):
    """
    Diagnosis and procedure codes sometimes include a qualifier prefix
    separated by a colon, e.g. "ABK:K0230".
    We only want the actual code part: "K0230".
    """
    if not code:
        return ""
    cleaned = clean_value(code)
    return cleaned.split(":")[-1] if ":" in cleaned else cleaned


def safe_int(value, default=0):
    """
    Convert a string to an integer, returning `default` if it fails.
    """
    if not value:
        return default
    try:
        return int(clean_value(value)) or default
    except (ValueError, AttributeError):
        return default


def safe_float(value, default=0.0):
    """
    Convert a string to a float, returning `default` if it fails.
    Used for dollar amounts and unit quantities.
    """
    if not value:
        return default
    try:
        cleaned = clean_value(value)
        return float(cleaned) if cleaned else default
    except (ValueError, AttributeError):
        return default


def el(elements, index, default=""):
    """
    Safe element accessor: returns elements[index] or `default` if the
    index is out of range.  Keeps the parsing code concise.
    """
    return elements[index] if len(elements) > index else default


# ─────────────────────────────────────────────────────────────────────────────
# MAIN PARSING FUNCTION
# ─────────────────────────────────────────────────────────────────────────────

def parse_x12_for_viewer(filepath):
    """
    Parse an X12 EDI file and return a list of section dicts ready for the
    Claim Viewer web application.

    The X12 format is segment-based: each segment starts with a 2-3 letter
    identifier followed by data elements separated by a delimiter (usually *).
    Example:  NM1*85*2*HAPPY VALLEY MEDICAL*****XX*1234567890~

    We read the file segment-by-segment, build up dicts for each part of
    the claim (subscriber, payer, service lines, etc.), and then package
    everything into a list of {"section": ..., "data": ...} objects that
    the Claim Viewer template knows how to display.

    Returns a single section list (one claim) or a list of lists (multiple
    claims found in the same file).
    """

    # ── Storage buckets for each logical section ──────────────────────────
    transaction      = {}
    submitter        = {}
    receiver         = {}
    billing_provider = {}
    pay_to_provider  = {}
    subscriber       = {}
    payer            = {}

    current_claim  = None   # the claim currently being built
    claims_data    = []     # all completed claims

    # Address data arrives in two segments (N3 = street, N4 = city/state/zip)
    # so we buffer it here and attach it when N4 is seen.
    temp_addresses = {}
    current_entity = None   # tracks which entity the last NM1/N3/N4 belongs to

    try:
        segments, ele_sep, seg_term = read_x12_segments(filepath)

        for seg_id, elements in segments:

            # ── ISA – Interchange Control Header ────────────────────────────
            # First segment in every X12 file; identifies sender and receiver.
            if seg_id == 'ISA':
                submitter['name'] = clean_value(el(elements, 6))
                receiver['name']  = clean_value(el(elements, 8))
                receiver['id']    = clean_value(el(elements, 8))

            # ── ST – Transaction Set Header ──────────────────────────────────
            # Marks the start of one transaction (e.g. one 837P claim batch).
            elif seg_id == 'ST':
                transaction['type']          = clean_value(el(elements, 1))
                transaction['controlNumber'] = clean_value(el(elements, 2))
                transaction['version']       = clean_value(el(elements, 3))

            # ── BHT – Beginning of Hierarchical Transaction ───────────────────
            # Contains submission date, time, and reference ID.
            elif seg_id == 'BHT':
                transaction['purpose']     = clean_value(el(elements, 1))
                transaction['referenceId'] = clean_value(el(elements, 3))
                transaction['date']        = parse_date(clean_value(el(elements, 4)))
                transaction['time']        = parse_time(clean_value(el(elements, 5)))

            # ── NM1 – Name / Entity Identifier ───────────────────────────────
            # Used for every named party in the claim.
            # Element [1] is an entity qualifier that tells us who this is:
            #   41 = Submitter,  40 = Receiver,  85 = Billing Provider,
            #   87 = Pay-To Provider,  IL = Insured/Subscriber (patient),
            #   PR = Payer,  82 = Rendering Provider,  77 = Service Facility
            elif seg_id == 'NM1':
                entity_code  = clean_value(el(elements, 1))
                entity_name  = clean_value(el(elements, 3))
                entity_fname = clean_value(el(elements, 4))
                entity_id    = clean_value(el(elements, 9))

                if entity_code == '41':       # Submitter
                    current_entity = 'submitter'
                    submitter['name'] = entity_name
                    submitter['id']   = entity_id

                elif entity_code == '40':     # Receiver
                    current_entity = 'receiver'
                    receiver['name'] = entity_name
                    receiver['id']   = entity_id

                elif entity_code == '85':     # Billing Provider
                    current_entity = 'billing_provider'
                    billing_provider['name']    = entity_name
                    billing_provider['taxId']   = entity_id
                    billing_provider['address'] = {}

                elif entity_code == '87':     # Pay-To Provider
                    current_entity = 'pay_to_provider'
                    pay_to_provider['name']    = entity_name
                    pay_to_provider['taxId']   = entity_id
                    pay_to_provider['address'] = {}

                elif entity_code == 'IL':     # Insured / Subscriber (patient)
                    current_entity = 'subscriber'
                    subscriber['firstName'] = entity_fname
                    subscriber['lastName']  = entity_name
                    subscriber['id']        = entity_id
                    subscriber['address']   = {}

                elif entity_code == 'PR':     # Payer (insurance company)
                    current_entity = 'payer'
                    payer_entry = {'name': entity_name, 'payerId': entity_id}
                    if current_claim:
                        current_claim['payer'] = payer_entry
                    else:
                        payer.update(payer_entry)

                elif entity_code == '82':     # Rendering Provider
                    current_entity = 'rendering_provider'
                    if current_claim:
                        current_claim['renderingProvider'] = {
                            'firstName': entity_fname,
                            'lastName':  entity_name,
                            'npi':       entity_id
                        }

                elif entity_code == '77':     # Service Facility
                    current_entity = 'service_facility'
                    if current_claim:
                        current_claim['serviceFacility'] = {
                            'name':    entity_name,
                            'taxId':   entity_id,
                            'address': {}
                        }

            # ── N3 – Street Address ──────────────────────────────────────────
            # Always follows the NM1 it belongs to; buffer it for N4.
            elif seg_id == 'N3':
                temp_addresses[current_entity] = {
                    'street': clean_value(el(elements, 1))
                }

            # ── N4 – City / State / ZIP ──────────────────────────────────────
            # Completes the address started by N3; attach to the right entity.
            elif seg_id == 'N4':
                if current_entity in temp_addresses:
                    temp_addresses[current_entity].update({
                        'city':  clean_value(el(elements, 1)),
                        'state': clean_value(el(elements, 2)),
                        'zip':   clean_value(el(elements, 3))
                    })
                    addr = temp_addresses[current_entity]

                    if current_entity == 'billing_provider':
                        billing_provider['address'] = addr
                    elif current_entity == 'pay_to_provider':
                        pay_to_provider['address'] = addr
                    elif current_entity == 'subscriber':
                        subscriber['address'] = addr
                    elif current_entity == 'service_facility' and current_claim:
                        if 'serviceFacility' in current_claim:
                            current_claim['serviceFacility']['address'] = addr

            # ── PER – Contact Information ────────────────────────────────────
            # Phone number / contact name for the submitter.
            elif seg_id == 'PER':
                if current_entity == 'submitter':
                    submitter['contact'] = {
                        'name':      clean_value(el(elements, 2)),
                        'phone':     clean_value(el(elements, 4)),
                        'extension': clean_value(el(elements, 6))
                    }

            # ── SBR – Subscriber Information ─────────────────────────────────
            # Insurance plan details for the subscriber.
            elif seg_id == 'SBR':
                subscriber['relationship'] = clean_value(el(elements, 2)) or 'self'
                subscriber['groupNumber']  = clean_value(el(elements, 3))
                subscriber['planType']     = clean_value(el(elements, 5))

            # ── DMG – Demographic Information ────────────────────────────────
            # Patient date of birth and sex.
            elif seg_id == 'DMG':
                if current_entity == 'subscriber':
                    subscriber['dob'] = parse_date(clean_value(el(elements, 2)))
                    subscriber['sex'] = clean_value(el(elements, 3))

            # ── CLM – Claim Information ──────────────────────────────────────
            # Each CLM segment opens a new claim.  Save the previous one first.
            elif seg_id == 'CLM':
                if current_claim:
                    claims_data.append(current_claim)

                current_claim = {
                    'id':             clean_value(el(elements, 1)),
                    'totalCharge':    safe_float(el(elements, 2)),
                    'placeOfService': "",
                    'serviceType':    "",
                    'indicators': {
                        'assigned':          clean_value(el(elements, 7)),
                        'providerSignature': clean_value(el(elements, 6)),
                        'releaseInfo':       clean_value(el(elements, 9)),
                        'patientSignature':  clean_value(el(elements, 8)),
                        'relatedCause':      ""
                    },
                    'onsetDate':                "",
                    'clearinghouseClaimNumber': "",
                    'diagnosis':    {'primary': "", 'secondary': []},
                    'serviceLines': []
                }

            # ── HI – Diagnosis Codes ─────────────────────────────────────────
            # ICD-10 codes: element 1 = primary, rest = secondary.
            elif seg_id == 'HI' and current_claim:
                for i in range(1, len(elements)):
                    if elements[i]:
                        code = clean_code(elements[i])
                        if code:
                            if i == 1:
                                current_claim['diagnosis']['primary'] = code
                            else:
                                current_claim['diagnosis']['secondary'].append(code)

            # ── DTP – Date / Time / Period ────────────────────────────────────
            # Reused for multiple date types; element [1] is the qualifier:
            #   472 = service date,  431/454 = onset / admission date
            elif seg_id == 'DTP':
                qualifier  = clean_value(el(elements, 1))
                date_value = parse_date(clean_value(el(elements, 3)))

                if qualifier == '472' and current_claim and current_claim['serviceLines']:
                    current_claim['serviceLines'][-1]['serviceDate'] = date_value
                elif qualifier in ('431', '454') and current_claim:
                    current_claim['onsetDate'] = date_value

            # ── REF – Reference Identification ──────────────────────────────
            # Qualifier D9 = clearinghouse claim number.
            elif seg_id == 'REF' and current_claim:
                if clean_value(el(elements, 1)) == 'D9':
                    current_claim['clearinghouseClaimNumber'] = clean_value(el(elements, 2))

            # ── LX – Service Line Number ─────────────────────────────────────
            # Opens a new service line; followed by SV1 and DTP.
            elif seg_id == 'LX' and current_claim:
                current_claim['serviceLines'].append({
                    'lineNumber':         safe_int(el(elements, 1)),
                    'codeQualifier':      "",
                    'procedureCode':      "",
                    'charge':             0,
                    'unitQualifier':      "",
                    'units':              0,
                    'diagnosisPointer':   "",
                    'emergencyIndicator': "",
                    'serviceDate':        ""
                })

            # ── SV1 – Professional Service ───────────────────────────────────
            # Details for one service line: procedure code, charge, units.
            elif seg_id == 'SV1' and current_claim and current_claim['serviceLines']:
                svc = current_claim['serviceLines'][-1]

                proc = clean_value(el(elements, 1))
                if ':' in proc:
                    parts = proc.split(':')
                    svc['codeQualifier'] = parts[0]
                    svc['procedureCode'] = parts[1] if len(parts) > 1 else proc
                else:
                    svc['procedureCode'] = proc

                svc['charge']        = safe_float(el(elements, 2))
                svc['unitQualifier'] = clean_value(el(elements, 3))
                svc['units']         = safe_float(el(elements, 4))

                pos = clean_value(el(elements, 5))
                if pos:
                    svc['placeOfService'] = pos
                    if not current_claim['placeOfService']:
                        current_claim['placeOfService'] = pos

                diag = el(elements, 7)
                if diag:
                    svc['diagnosisPointer'] = safe_int(diag)

        # ── End of file: save the last open claim ────────────────────────────
        if current_claim:
            claims_data.append(current_claim)

        # If no Pay-To Provider was specified, default to the billing provider
        if not pay_to_provider.get('name'):
            pay_to_provider = billing_provider.copy()

        if not claims_data:
            # Build a helpful diagnostic so the user (and developer) can
            # understand exactly what is in the file.
            found_ids = sorted(set(sid for sid, _ in segments))
            trans_type = transaction.get('type', 'unknown')

            # Map common transaction set IDs to human-readable names
            tx_names = {
                '835': '835 Remittance Advice (payment file – not a claim)',
                '270': '270 Eligibility Inquiry',
                '271': '271 Eligibility Response',
                '276': '276 Claim Status Request',
                '277': '277 Claim Status Response',
                '278': '278 Prior Authorization',
                '834': '834 Benefit Enrollment',
            }
            tx_label = tx_names.get(trans_type, f'transaction type {trans_type}')

            raise RuntimeError(
                f"No CLM (claim) segments found in this file. "
                f"Transaction type detected: {tx_label}. "
                f"Segment types present: {', '.join(found_ids)}. "
                f"Detected element separator: '{ele_sep}', "
                f"segment terminator: repr='{repr(seg_term)}'. "
                "This parser handles 837P/837I/837D claim files only."
            )

        # ── Build output: one section array per claim ─────────────────────────
        # The Claim Viewer expects each claim as a list of
        # {"section": "<name>", "data": {...}} objects.
        results = []

        for claim_data in claims_data:
            sections = [
                {"section": "transaction",      "data": transaction},
                {"section": "submitter",        "data": submitter},
                {"section": "receiver",         "data": receiver},
                {"section": "billing_Provider", "data": billing_provider},
                {"section": "Pay_To_provider",  "data": pay_to_provider},
                {"section": "subscriber",       "data": subscriber},
                {"section": "payer",            "data": claim_data.get('payer', payer)},
                {"section": "claim",            "data": {
                    'id':                       claim_data['id'],
                    'totalCharge':              claim_data['totalCharge'],
                    'placeOfService':           claim_data['placeOfService'],
                    'serviceType':              claim_data['serviceType'],
                    'indicators':               claim_data['indicators'],
                    'onsetDate':                claim_data['onsetDate'],
                    'clearinghouseClaimNumber': claim_data['clearinghouseClaimNumber']
                }},
                {"section": "diagnosis",         "data": claim_data['diagnosis']},
                {"section": "renderingProvider", "data": claim_data.get('renderingProvider', {})},
                {"section": "serviceFacility",   "data": claim_data.get('serviceFacility', billing_provider)},
                {"section": "service_Lines",     "data": claim_data['serviceLines']}
            ]
            results.append(sections)

        # Single claim → return sections directly
        # Multiple claims → return list of section arrays
        return results[0] if len(results) == 1 else results

    except RuntimeError:
        raise   # pass our descriptive errors through unchanged
    except Exception as e:
        raise RuntimeError(f"Unexpected error parsing X12 file: {e}")


# ─────────────────────────────────────────────────────────────────────────────
# COMMAND-LINE ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("X12 Parser for Claim Viewer")
        print("Usage: python3 parser_for_viewer.py <input_file> [output_file]")
        sys.exit(1)

    input_file = sys.argv[1]

    if not os.path.exists(input_file):
        print(f"Error: file not found: {input_file}")
        sys.exit(1)

    if len(sys.argv) >= 3:
        output_file = sys.argv[2]
    else:
        os.makedirs("output_files_viewer", exist_ok=True)
        base = os.path.splitext(os.path.basename(input_file))[0]
        output_file = f"output_files_viewer/{base}_claim.json"

    print(f"Parsing: {input_file}")

    try:
        data = parse_x12_for_viewer(input_file)

        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)

        print(f"Done → {output_file}")

    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
