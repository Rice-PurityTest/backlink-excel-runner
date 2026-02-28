#!/usr/bin/env python3
"""
Minimal XLSX operations for backlink-excel-runner.

Design goals:
- Easy to read and change for beginners.
- Single responsibility: read/write status cells safely.
- No third-party deps (pure stdlib + XML in XLSX).
"""

import datetime
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET


NS = {
    "x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
}
ET.register_namespace("", NS["x"])
ET.register_namespace("r", NS["r"])


def load_cfg(cfg_path: str) -> dict:
    with open(cfg_path, "r", encoding="utf-8") as f:
        return json.load(f)


def sst_values(sst: ET.Element) -> list[str]:
    """Return the shared strings list (order matters)."""
    values: list[str] = []
    for si in sst.findall("x:si", NS):
        # Shared strings may contain multiple <t> nodes.
        text = "".join((t.text or "") for t in si.findall(".//x:t", NS))
        values.append(text)
    return values


def cell_val(cell: ET.Element | None, sst_vals: list[str]) -> str:
    """Read cell string value (string table or raw)."""
    if cell is None:
        return ""
    v = cell.find("x:v", NS)
    if v is None:
        return ""
    raw = v.text or ""
    if cell.attrib.get("t") == "s":
        try:
            return sst_vals[int(raw)]
        except Exception:
            return raw
    return raw


def set_shared(cell: ET.Element, text: str, sst: ET.Element, sst_vals: list[str]) -> None:
    """Write a string into sharedStrings and set the cell to reference it."""
    try:
        idx = sst_vals.index(text)
    except ValueError:
        idx = len(sst_vals)
        si = ET.Element(f"{{{NS['x']}}}si")
        t = ET.SubElement(si, f"{{{NS['x']}}}t")
        t.text = text
        sst.append(si)
        sst_vals.append(text)

    cell.attrib["t"] = "s"
    v = cell.find("x:v", NS)
    if v is None:
        v = ET.SubElement(cell, f"{{{NS['x']}}}v")
    v.text = str(idx)


def load_sheet(xlsx_path: str, sheet_name: str):
    """Load worksheet XML + sharedStrings from XLSX."""
    zin = zipfile.ZipFile(xlsx_path, "r")
    wb = ET.fromstring(zin.read("xl/workbook.xml"))
    rel = ET.fromstring(zin.read("xl/_rels/workbook.xml.rels"))

    relmap = {x.attrib["Id"]: x.attrib["Target"] for x in rel}
    rid = None
    for s in wb.findall(".//x:sheets/x:sheet", NS):
        if s.attrib.get("name") == sheet_name:
            rid = s.attrib.get(
                "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
            )
            break
    if not rid:
        raise SystemExit(f"sheet not found: {sheet_name}")

    target = relmap[rid]
    if not target.startswith("xl/"):
        target = "xl/" + target

    sh = ET.fromstring(zin.read(target))
    if "xl/sharedStrings.xml" in zin.namelist():
        sst = ET.fromstring(zin.read("xl/sharedStrings.xml"))
    else:
        sst = ET.Element(f"{{{NS['x']}}}sst")

    return zin, target, sh, sst


def save_sheet(xlsx_path: str, target: str, sh: ET.Element, sst: ET.Element, sst_vals: list[str]) -> None:
    """Write updated worksheet + sharedStrings back to XLSX."""
    sst.attrib["count"] = str(len(sst_vals))
    sst.attrib["uniqueCount"] = str(len(sst_vals))

    fd, tmp = tempfile.mkstemp(suffix=".xlsx")
    os.close(fd)

    with zipfile.ZipFile(xlsx_path, "r") as zin2, zipfile.ZipFile(
        tmp, "w", compression=zipfile.ZIP_DEFLATED
    ) as zout:
        for item in zin2.infolist():
            data = zin2.read(item.filename)
            if item.filename == target:
                data = ET.tostring(sh, encoding="utf-8", xml_declaration=True)
            elif item.filename == "xl/sharedStrings.xml":
                data = ET.tostring(sst, encoding="utf-8", xml_declaration=True)
            zout.writestr(item, data)

    shutil.move(tmp, xlsx_path)


def find_cell(row: ET.Element, ref: str) -> ET.Element:
    """Find cell by ref, create if missing."""
    for cell in row.findall("x:c", NS):
        if cell.attrib.get("r") == ref:
            return cell
    return ET.SubElement(row, f"{{{NS['x']}}}c", {"r": ref})


def parse_status(status_raw: str) -> dict:
    """Parse status string like IN_PROGRESS | runId=.. | worker=.. | retry=.. | ts=.."""
    return {
        "raw": status_raw,
        "worker": (re.search(r"worker=([^|]+)", status_raw) or [None, ""])[1].strip(),
        "runId": (re.search(r"runId=([^|]+)", status_raw) or [None, ""])[1].strip(),
        "ts": (re.search(r"ts=([^|]+)", status_raw) or [None, ""])[1].strip(),
        "retry": int((re.search(r"retry=(\d+)", status_raw) or [None, "0"])[1]),
    }


def now_utc8() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))


def print_json(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False))


def cmd_in_progress_info(cfg: dict) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]
    url_col = cols["url"]
    worker = cfg.get("worker", "openclaw-main")
    lock_timeout_min = int(cfg.get("runtime", {}).get("lockTimeoutMinutes", 10))

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    now_dt = now_utc8()

    for row in sheet_data.findall("x:row", NS):
        r = int(row.attrib.get("r", "0"))
        if r <= 1:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
        st = st_raw.upper()
        if not st.startswith("IN_PROGRESS"):
            continue

        info = parse_status(st_raw)
        url = str(cell_val(m.get(url_col), sst_vals)).strip()

        stale = False
        age_seconds = None
        if info["ts"]:
            try:
                lock_dt = datetime.datetime.fromisoformat(info["ts"])
                if lock_dt.tzinfo is None:
                    lock_dt = lock_dt.replace(
                        tzinfo=datetime.timezone(datetime.timedelta(hours=8))
                    )
                age_seconds = int((now_dt - lock_dt).total_seconds())
                stale = age_seconds >= lock_timeout_min * 60
            except Exception:
                stale = False

        print_json(
            {
                "ok": True,
                "message": "in_progress",
                "row": r,
                "url": url,
                "status": st_raw,
                "worker": info["worker"],
                "runId": info["runId"],
                "retry": info["retry"],
                "ts": info["ts"],
                "stale": stale,
                "ageSeconds": age_seconds,
                "lockTimeoutMinutes": lock_timeout_min,
                "expectedWorker": worker,
            }
        )
        return

    print_json({"ok": True, "message": "none"})


def cmd_claim_next(cfg: dict) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]
    url_col = cols["url"]
    landing_col = cols["landing"]
    worker = cfg.get("worker", "openclaw-main")

    lock_timeout_min = int(cfg.get("runtime", {}).get("lockTimeoutMinutes", 10))
    max_retry_per_row = int(cfg.get("runtime", {}).get("maxRetryPerRow", 1))

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    now_dt = now_utc8()

    # Serial-only guard + stale lock recycle
    for row in sheet_data.findall("x:row", NS):
        r = int(row.attrib.get("r", "0"))
        if r <= 1:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        url = str(cell_val(m.get(url_col), sst_vals)).strip()
        st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
        st = st_raw.upper()
        if not url:
            continue
        if st.startswith("IN_PROGRESS"):
            info = parse_status(st_raw)
            # never overwrite another worker lock
            if info["worker"] and info["worker"] != worker:
                print_json(
                    {
                        "ok": True,
                        "message": "in_progress_exists",
                        "row": r,
                        "url": url,
                        "status": st_raw,
                    }
                )
                raise SystemExit(0)

            # recycle stale lock -> RETRY_PENDING
            stale = False
            if info["ts"]:
                try:
                    lock_dt = datetime.datetime.fromisoformat(info["ts"])
                    if lock_dt.tzinfo is None:
                        lock_dt = lock_dt.replace(
                            tzinfo=datetime.timezone(datetime.timedelta(hours=8))
                        )
                    age_sec = (now_dt - lock_dt).total_seconds()
                    if age_sec >= lock_timeout_min * 60:
                        stale = True
                except Exception:
                    stale = False

            if stale:
                ref = f"{status_col}{r}"
                cell = find_cell(row, ref)
                ts = now_dt.isoformat(timespec="seconds")
                next_retry = info["retry"] + 1
                if next_retry >= max_retry_per_row:
                    set_shared(
                        cell,
                        f"NEED_HUMAN | reason=retry_exceeded_after_lock_timeout | retry={next_retry} | ts={ts}",
                        sst,
                        sst_vals,
                    )
                else:
                    set_shared(
                        cell,
                        f"RETRY_PENDING | reason=lock_timeout | retry={next_retry} | ts={ts}",
                        sst,
                        sst_vals,
                    )
                save_sheet(xlsx, target, sh, sst, sst_vals)
                # continue scan after recycle/finalize
                continue

            print_json(
                {
                    "ok": True,
                    "message": "in_progress_exists",
                    "row": r,
                    "url": url,
                    "status": st_raw,
                }
            )
            raise SystemExit(0)

    picked = None
    for row in sheet_data.findall("x:row", NS):
        r = int(row.attrib.get("r", "0"))
        if r <= 1:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        url = str(cell_val(m.get(url_col), sst_vals)).strip()
        st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
        st = st_raw.upper()
        if not url:
            continue

        # hard-stop rows that exceeded retry budget
        if st.startswith("RETRY_PENDING"):
            mr_retry = re.search(r"retry=(\d+)", st_raw)
            retry_val = int(mr_retry.group(1)) if mr_retry else 1
            if retry_val >= max_retry_per_row:
                ref = f"{status_col}{r}"
                cell = find_cell(row, ref)
                ts = now_dt.isoformat(timespec="seconds")
                set_shared(
                    cell,
                    f"NEED_HUMAN | reason=retry_exceeded | retry={retry_val} | ts={ts}",
                    sst,
                    sst_vals,
                )
                save_sheet(xlsx, target, sh, sst, sst_vals)
                continue

        if st == "" or st.startswith("PENDING") or st.startswith("RETRY_PENDING"):
            picked = (row, r, url, st_raw)
            break

    if not picked:
        print_json({"ok": True, "message": "no_pending_rows"})
        raise SystemExit(0)

    row, r, url, prev_status_raw = picked

    # invalid URL fast skip
    if not re.match(r"^https?://", url, re.I):
        ref = f"{status_col}{r}"
        cell = find_cell(row, ref)
        set_shared(cell, "SKIP | reason=empty_or_invalid_url", sst, sst_vals)
        save_sheet(xlsx, target, sh, sst, sst_vals)
        print_json(
            {
                "ok": True,
                "row": r,
                "url": url,
                "status": "SKIP | reason=empty_or_invalid_url",
            }
        )
        raise SystemExit(0)

    run_id = "run-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    ts = now_utc8().isoformat(timespec="seconds")
    prev_retry = 0
    if prev_status_raw.upper().startswith("RETRY_PENDING"):
        mr_retry = re.search(r"retry=(\d+)", prev_status_raw)
        prev_retry = int(mr_retry.group(1)) if mr_retry else 1

    status = (
        f"IN_PROGRESS | runId={run_id} | worker={worker} | row={r} "
        f"| retry={prev_retry} | ts={ts}"
    )

    ref = f"{status_col}{r}"
    cell = find_cell(row, ref)
    set_shared(cell, status, sst, sst_vals)
    save_sheet(xlsx, target, sh, sst, sst_vals)

    print_json({"ok": True, "row": r, "url": url, "runId": run_id, "status": status})


def cmd_list_next_n(cfg: dict, n: int) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]
    url_col = cols["url"]
    worker = cfg.get("worker", "openclaw-main")
    lock_timeout_min = int(cfg.get("runtime", {}).get("lockTimeoutMinutes", 10))
    max_retry_per_row = int(cfg.get("runtime", {}).get("maxRetryPerRow", 1))

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    now_dt = now_utc8()
    dirty = False

    # Serial-only guard + stale lock recycle
    for row in sheet_data.findall("x:row", NS):
        r = int(row.attrib.get("r", "0"))
        if r <= 1:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        url = str(cell_val(m.get(url_col), sst_vals)).strip()
        st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
        st = st_raw.upper()
        if not url:
            continue
        if st.startswith("IN_PROGRESS"):
            info = parse_status(st_raw)
            if info["worker"] and info["worker"] != worker:
                if dirty:
                    save_sheet(xlsx, target, sh, sst, sst_vals)
                print_json(
                    {
                        "ok": True,
                        "message": "in_progress_exists",
                        "row": r,
                        "url": url,
                        "status": st_raw,
                        "worker": info["worker"],
                    }
                )
                return

            stale = False
            if info["ts"]:
                try:
                    lock_dt = datetime.datetime.fromisoformat(info["ts"])
                    if lock_dt.tzinfo is None:
                        lock_dt = lock_dt.replace(
                            tzinfo=datetime.timezone(datetime.timedelta(hours=8))
                        )
                    age_sec = (now_dt - lock_dt).total_seconds()
                    if age_sec >= lock_timeout_min * 60:
                        stale = True
                except Exception:
                    stale = False

            if stale:
                ref = f"{status_col}{r}"
                cell = find_cell(row, ref)
                ts = now_dt.isoformat(timespec="seconds")
                next_retry = info["retry"] + 1
                if next_retry >= max_retry_per_row:
                    set_shared(
                        cell,
                        f"NEED_HUMAN | reason=retry_exceeded_after_lock_timeout | retry={next_retry} | ts={ts}",
                        sst,
                        sst_vals,
                    )
                else:
                    set_shared(
                        cell,
                        f"RETRY_PENDING | reason=lock_timeout | retry={next_retry} | ts={ts}",
                        sst,
                        sst_vals,
                    )
                dirty = True
                continue

            if dirty:
                save_sheet(xlsx, target, sh, sst, sst_vals)
            print_json(
                {
                    "ok": True,
                    "message": "in_progress_exists",
                    "row": r,
                    "url": url,
                    "status": st_raw,
                    "worker": info["worker"],
                }
            )
            return

    rows = []
    for row in sheet_data.findall("x:row", NS):
        r = int(row.attrib.get("r", "0"))
        if r <= 1:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        url = str(cell_val(m.get(url_col), sst_vals)).strip()
        st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
        st = st_raw.upper()
        if not url:
            continue
        if st.startswith("IN_PROGRESS"):
            continue
        if st.startswith("RETRY_PENDING"):
            mr_retry = re.search(r"retry=(\d+)", st_raw)
            retry_val = int(mr_retry.group(1)) if mr_retry else 1
            if retry_val >= max_retry_per_row:
                ref = f"{status_col}{r}"
                cell = find_cell(row, ref)
                ts = now_dt.isoformat(timespec="seconds")
                set_shared(
                    cell,
                    f"NEED_HUMAN | reason=retry_exceeded | retry={retry_val} | ts={ts}",
                    sst,
                    sst_vals,
                )
                dirty = True
                continue
        if st == "" or st.startswith("PENDING") or st.startswith("RETRY_PENDING"):
            rows.append({"row": r, "url": url, "status": st_raw})
        if len(rows) >= n:
            break

    if dirty:
        save_sheet(xlsx, target, sh, sst, sst_vals)

    if not rows:
        print_json({"ok": True, "message": "no_pending_rows", "rows": []})
        return

    print_json({"ok": True, "rows": rows})


def cmd_claim_row(cfg: dict, row_num: int) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]
    url_col = cols["url"]
    worker = cfg.get("worker", "openclaw-main")
    max_retry_per_row = int(cfg.get("runtime", {}).get("maxRetryPerRow", 1))

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    row = None
    for rr in sheet_data.findall("x:row", NS):
        if int(rr.attrib.get("r", "0")) == row_num:
            row = rr
            break
    if row is None:
        print_json({"ok": False, "message": "row_not_found", "row": row_num})
        return

    m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
    url = str(cell_val(m.get(url_col), sst_vals)).strip()
    st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
    st = st_raw.upper()

    if not url or not re.match(r"^https?://", url, re.I):
        ref = f"{status_col}{row_num}"
        cell = find_cell(row, ref)
        set_shared(cell, "SKIP | reason=empty_or_invalid_url", sst, sst_vals)
        save_sheet(xlsx, target, sh, sst, sst_vals)
        print_json(
            {
                "ok": True,
                "message": "skipped_invalid_url",
                "row": row_num,
                "url": url,
                "status": "SKIP | reason=empty_or_invalid_url",
            }
        )
        return

    if st.startswith("IN_PROGRESS"):
        info = parse_status(st_raw)
        if info["worker"] and info["worker"] != worker:
            print_json(
                {
                    "ok": True,
                    "message": "in_progress_exists",
                    "row": row_num,
                    "url": url,
                    "status": st_raw,
                    "worker": info["worker"],
                }
            )
            return
        print_json(
            {
                "ok": True,
                "message": "already_in_progress",
                "row": row_num,
                "url": url,
                "status": st_raw,
            }
        )
        return

    if st.startswith("DONE") or st.startswith("FAILED") or st.startswith("SKIP") or st.startswith("NEED_HUMAN"):
        print_json(
            {
                "ok": True,
                "message": "skipped_final",
                "row": row_num,
                "url": url,
                "status": st_raw,
            }
        )
        return

    if st.startswith("RETRY_PENDING"):
        mr_retry = re.search(r"retry=(\d+)", st_raw)
        retry_val = int(mr_retry.group(1)) if mr_retry else 1
        if retry_val >= max_retry_per_row:
            ref = f"{status_col}{row_num}"
            cell = find_cell(row, ref)
            ts = now_utc8().isoformat(timespec="seconds")
            set_shared(
                cell,
                f"NEED_HUMAN | reason=retry_exceeded | retry={retry_val} | ts={ts}",
                sst,
                sst_vals,
            )
            save_sheet(xlsx, target, sh, sst, sst_vals)
            print_json(
                {
                    "ok": True,
                    "message": "need_human_retry_exceeded",
                    "row": row_num,
                    "url": url,
                    "status": f"NEED_HUMAN | reason=retry_exceeded | retry={retry_val} | ts={ts}",
                }
            )
            return

    run_id = "run-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    ts = now_utc8().isoformat(timespec="seconds")
    prev_retry = 0
    if st.startswith("RETRY_PENDING"):
        mr_retry = re.search(r"retry=(\d+)", st_raw)
        prev_retry = int(mr_retry.group(1)) if mr_retry else 1

    status = (
        f"IN_PROGRESS | runId={run_id} | worker={worker} | row={row_num} "
        f"| retry={prev_retry} | ts={ts}"
    )
    ref = f"{status_col}{row_num}"
    cell = find_cell(row, ref)
    set_shared(cell, status, sst, sst_vals)
    save_sheet(xlsx, target, sh, sst, sst_vals)

    print_json(
        {"ok": True, "message": "claimed", "row": row_num, "url": url, "runId": run_id, "status": status}
    )


def cmd_set_final(cfg: dict, row_num: int, status_text: str, landing: str) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]
    landing_col = cols["landing"]

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    row = None
    for rr in sheet_data.findall("x:row", NS):
        if int(rr.attrib.get("r", "0")) == row_num:
            row = rr
            break
    if row is None:
        row = ET.SubElement(sheet_data, f"{{{NS['x']}}}row", {"r": str(row_num)})

    for colname, text in [(status_col, status_text), (landing_col, landing)]:
        ref = f"{colname}{row_num}"
        cell = find_cell(row, ref)
        set_shared(cell, text, sst, sst_vals)

    save_sheet(xlsx, target, sh, sst, sst_vals)
    print_json({"ok": True, "row": row_num, "status": status_text, "landing": landing})


def cmd_pending_count(cfg: dict) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]
    url_col = cols["url"]

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    cnt = 0
    for row in sheet_data.findall("x:row", NS):
        r = int(row.attrib.get("r", "0"))
        if r <= 1:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        url = str(cell_val(m.get(url_col), sst_vals)).strip()
        st = str(cell_val(m.get(status_col), sst_vals)).strip().upper()
        if not url:
            continue
        if st == "" or st.startswith("PENDING") or st.startswith("RETRY_PENDING") or st.startswith("IN_PROGRESS"):
            cnt += 1
    print(cnt)


def cmd_get_status(cfg: dict, row_num: int) -> None:
    xlsx = cfg["filePath"]
    sheet_name = cfg["sheetName"]
    cols = cfg["columns"]
    status_col = cols["status"]

    zin, target, sh, sst = load_sheet(xlsx, sheet_name)
    sheet_data = sh.find("x:sheetData", NS)
    sst_vals = sst_values(sst)

    for row in sheet_data.findall("x:row", NS):
        if int(row.attrib.get("r", "0")) != row_num:
            continue
        m = {re.sub(r"\d", "", c.attrib.get("r", "")): c for c in row.findall("x:c", NS)}
        st_raw = str(cell_val(m.get(status_col), sst_vals)).strip()
        print(st_raw)
        return

    print("")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("Usage: xlsx_ops.py <mode> <config.json> [args...]")

    mode = sys.argv[1]
    cfg_path = sys.argv[2]
    cfg = load_cfg(cfg_path)

    if mode == "in_progress_info":
        cmd_in_progress_info(cfg)
    elif mode == "claim_next":
        cmd_claim_next(cfg)
    elif mode == "list_next_n":
        if len(sys.argv) < 4:
            raise SystemExit("list_next_n requires: n")
        n = int(sys.argv[3])
        cmd_list_next_n(cfg, n)
    elif mode == "claim_row":
        if len(sys.argv) < 4:
            raise SystemExit("claim_row requires: row")
        row_num = int(sys.argv[3])
        cmd_claim_row(cfg, row_num)
    elif mode == "set_final":
        if len(sys.argv) < 5:
            raise SystemExit("set_final requires: row status_text [landing]")
        row_num = int(sys.argv[3])
        status_text = sys.argv[4]
        landing = sys.argv[5] if len(sys.argv) > 5 else ""
        cmd_set_final(cfg, row_num, status_text, landing)
    elif mode == "pending_count":
        cmd_pending_count(cfg)
    elif mode == "get_status":
        if len(sys.argv) < 4:
            raise SystemExit("get_status requires: row")
        row_num = int(sys.argv[3])
        cmd_get_status(cfg, row_num)
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
