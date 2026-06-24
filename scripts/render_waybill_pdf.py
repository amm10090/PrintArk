#!/usr/bin/env python3
"""Render a task-specific Cainiao/Taobao waybill PDF from a 13528 print payload."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont
from reportlab.lib.pagesizes import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas


PAGE_W_MM = 74
PAGE_H_MM = 126
PAGE_W_PT = PAGE_W_MM * mm
PAGE_H_PT = PAGE_H_MM * mm
PX_PER_MM = 8
PAGE_W_PX = PAGE_W_MM * PX_PER_MM
PAGE_H_PX = PAGE_H_MM * PX_PER_MM
MARGIN = 0
CAINIAO_CACHE_DIR = Path("/Users/amo/cainiao-x-print/caches")
WAYBILL_DEFAULT_KEY = bytes([
    0xCD, 0xBF, 0xFD, 0x0A, 0xC5, 0x9D, 0xE5, 0x6D,
    0x3F, 0x17, 0xF9, 0x3A, 0x7E, 0xED, 0xFF, 0x57,
])
WAYBILL_KEYS = {
    "waybill_print_secret_version_1": WAYBILL_DEFAULT_KEY,
    "": WAYBILL_DEFAULT_KEY,
}
FONT_PATHS = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/AppleGothic.ttf",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="-", help="print payload JSON path, or '-' for stdin")
    parser.add_argument("--output-dir", default="/tmp/tabooprint/waybills")
    parser.add_argument("--request-id", default="")
    parser.add_argument("--task-id", default="")
    args = parser.parse_args()

    payload = load_payload(args.input)
    request_id = args.request_id or str(payload.get("requestID") or f"RENDER_{int(time.time() * 1000)}")
    task = payload.get("task") or {}
    task_id = args.task_id or str(task.get("taskID") or request_id)
    output_dir = Path(args.output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    output_path = output_dir / f"{safe_filename(task_id)}.pdf"
    render_pdf(payload, output_path, request_id, task_id)

    print(json.dumps({
        "ok": True,
        "path": str(output_path),
        "fileName": output_path.name,
        "documentIds": document_ids(payload),
    }, ensure_ascii=False))
    return 0


def load_payload(input_path: str) -> dict[str, Any]:
    raw = sys.stdin.read() if input_path == "-" else Path(input_path).read_text(encoding="utf-8")
    return json.loads(raw)


def render_pdf(payload: dict[str, Any], output_path: Path, request_id: str, task_id: str) -> None:
    c = canvas.Canvas(str(output_path), pagesize=(PAGE_W_PT, PAGE_H_PT))
    c.setTitle(f"Tabooprint {task_id}")

    task = payload.get("task") or {}
    documents = task.get("documents") if isinstance(task.get("documents"), list) else []
    if not documents:
        image = draw_empty_page(request_id, task_id)
        draw_page(c, image, "")
        c.save()
        return

    for index, document in enumerate(documents):
        if index:
            c.showPage()
        image = draw_document_image(payload, document, request_id, task_id, index + 1, len(documents))
        doc_id = text(document.get("documentID") or document.get("documentId"))
        if not doc_id:
            _, custom = split_contents(document)
            data = custom.get("data") if isinstance(custom.get("data"), dict) else {}
            doc_id = text(data.get("WAIBILLNO_BAR_CODE"))
        draw_page(c, image, doc_id)

    c.save()


def draw_page(c: canvas.Canvas, image: Image.Image, document_id: str) -> None:
    c.drawImage(ImageReader(image), 0, 0, width=PAGE_W_PT, height=PAGE_H_PT)


def draw_document_image(
    payload: dict[str, Any],
    document: dict[str, Any],
    request_id: str,
    task_id: str,
    page_no: int,
    page_count: int,
) -> Image.Image:
    image = Image.new("RGB", (PAGE_W_PX, PAGE_H_PX), "white")
    draw = ImageDraw.Draw(image)
    fonts = FontBook()

    standard, custom = split_contents(document)
    custom_data = custom.get("data") if isinstance(custom.get("data"), dict) else {}
    sender = ((standard.get("addData") or {}).get("sender") or {}) if isinstance(standard.get("addData"), dict) else {}
    document_id = text(document.get("documentID") or document.get("documentId") or custom_data.get("WAIBILLNO_BAR_CODE"))
    task = payload.get("task") or {}

    decrypted = decrypt_waybill_content(standard)
    if sender:
        merge_sender_add_data(decrypted, sender)

    draw_cainiao_300336(image, draw, fonts, decrypted, standard, custom, custom_data, document_id, page_no, page_count)
    if should_draw_debug_footer():
        draw_debug_footer(draw, fonts, request_id, task_id, task, standard, custom)
    return image


def draw_empty_page(request_id: str, task_id: str) -> Image.Image:
    image = Image.new("RGB", (PAGE_W_PX, PAGE_H_PX), "white")
    draw = ImageDraw.Draw(image)
    fonts = FontBook()
    draw.rectangle([MARGIN, MARGIN, PAGE_W_PX - MARGIN, PAGE_H_PX - MARGIN], outline="black", width=2)
    draw.text((MARGIN + 16, MARGIN + 24), "Tabooprint 空任务", fill="black", font=fonts.font(34))
    draw.text((MARGIN + 16, MARGIN + 92), f"requestID: {request_id}", fill="black", font=fonts.font(20))
    draw.text((MARGIN + 16, MARGIN + 128), f"taskID: {task_id}", fill="black", font=fonts.font(20))
    draw.text((MARGIN + 16, MARGIN + 196), "print payload 中没有 documents。", fill="black", font=fonts.font(24))
    return image


def split_contents(document: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    contents = document.get("contents") if isinstance(document.get("contents"), list) else []
    standard: dict[str, Any] = {}
    custom: dict[str, Any] = {}
    for item in contents:
        if not isinstance(item, dict):
            continue
        if item.get("encryptedData") or item.get("ver"):
            standard = item
        elif item.get("data"):
            custom = item
    return standard, custom


def decrypt_waybill_content(standard: dict[str, Any]) -> dict[str, Any]:
    encrypted = text(standard.get("encryptedData"))
    if not encrypted:
        return {}
    if not encrypted.startswith("AES:"):
        return {}
    key = WAYBILL_KEYS.get(text(standard.get("ver")), WAYBILL_DEFAULT_KEY)
    ciphertext = base64.b64decode(encrypted[len("AES:"):])
    raw = decrypt_aes_ecb(ciphertext, key)
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def decrypt_aes_ecb(ciphertext: bytes, key: bytes) -> bytes:
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.padding import PKCS7

        decryptor = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
        padded = decryptor.update(ciphertext) + decryptor.finalize()
        unpadder = PKCS7(128).unpadder()
        return unpadder.update(padded) + unpadder.finalize()
    except Exception:
        proc = subprocess.run(
            ["/usr/bin/openssl", "enc", "-d", "-aes-128-ecb", "-K", key.hex(), "-nosalt"],
            input=ciphertext,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        return proc.stdout


def merge_sender_add_data(data: dict[str, Any], sender: dict[str, Any]) -> None:
    if not sender:
        return
    data_sender = data.setdefault("sender", {})
    if not isinstance(data_sender, dict):
        data["sender"] = {}
        data_sender = data["sender"]
    deep_merge(data_sender, sender)


def deep_merge(target: dict[str, Any], source: dict[str, Any]) -> None:
    for key, value in source.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            deep_merge(target[key], value)
        elif value not in (None, ""):
            target[key] = value


def draw_cainiao_300336(
    image: Image.Image,
    draw: ImageDraw.ImageDraw,
    fonts: "FontBook",
    data: dict[str, Any],
    standard: dict[str, Any],
    custom: dict[str, Any],
    custom_data: dict[str, Any],
    document_id: str,
    page_no: int,
    page_count: int,
) -> None:
    values = build_template_values(data, document_id, page_no, page_count)
    draw.rectangle([mm_px(5), mm_px(0.6), mm_px(70), mm_px(126)], outline="black", width=1)

    draw_cached_image(image, "https://cdn-cloudprint.cainiao.com/waybill-print/templateImages/tao.png", 26.32, 2.58, 6.92, 5.31)
    draw_template_text(draw, fonts, "快递\n包裹", 59, 0.8, 11, 11, size=5.4, bold=True, align="center", valign="middle")
    draw_rotated_text(image, fonts, values["waybillCode"], 0.6, 22, 90, size=3.2)
    draw_rotated_text(image, fonts, values["waybillCode"], 71.6, 22, 90, size=3.2)
    draw_template_text(draw, fonts, values["yyyyMMdd"], 2.06, 9, 14, 3, size=2.7, align="right")
    draw_template_text(draw, fonts, values["hhmmss"], 17.06, 9, 13, 3, size=2.7, align="center")
    draw_template_text(draw, fonts, f"第{page_no}/{page_count}个", 31.15, 9, 16.03, 3, size=2.7)
    draw_template_text(draw, fonts, values["datoubi"], 7.33, 12.24, 61, 8.41, size=7, bold=True, align="center", valign="bottom")
    draw_code128(draw, values["waybillCode"], 8.65, 21.76, 57.85, 15.56, show_text=True)
    draw_template_text(draw, fonts, values["consolidation"], 12.86, 37.98, 27.44, 6.83, size=5.2, bold=True, valign="middle")
    draw_template_text(draw, fonts, values["prefixCode"], 40.66, 38.1, 8.86, 6.85, size=5.3, fill="white", background="black", align="center", valign="middle")
    draw_template_text(draw, fonts, values["blockCode"], 49.89, 38.58, 18.67, 6.42, size=4.5, valign="middle")

    draw_cached_image(image, "http://cdn-cloudprint.cainiao.com/waybill-print/cloudprint-imgs/72b8ad20254d445586413efa4edd5588.png", 5.4, 37.97, 7, 7)
    draw_cached_image(image, "http://cdn-cloudprint.cainiao.com/waybill-print/cloudprint-imgs/a9811ef066ce479286af4c583e52b95e.png", 5.1, 51.03, 6, 6)
    draw_cached_image(image, "http://cdn-cloudprint.cainiao.com/waybill-print/cloudprint-imgs/17de5cff6c1147b3934b9693044cb809.png", 5.44, 62.92, 4, 4)

    for x1, y1, x2, y2, width in [
        (5.35, 12, 70, 12, 1),
        (5.08, 21, 70, 21, 1),
        (5.19, 37.79, 69.99, 37.79, 1),
        (5.08, 45, 70, 45, 1),
        (5.08, 50.03, 70, 50.03, 1),
        (5.48, 63, 70, 63, 1),
        (5.09, 68, 70, 68, 1),
        (5.09, 76, 70.27, 76, 1),
        (33, 68.5, 33, 76, 1),
    ]:
        draw.line([mm_px(x1), mm_px(y1), mm_px(x2), mm_px(y2)], fill="black", width=width)

    draw_template_text(
        draw,
        fonts,
        f"{values['recipientName']}  {values['recipientMobile']}\n{values['recipientAddress']}",
        11.84,
        50.32,
        57.74,
        12.04,
        size=3.7,
        wrap=True,
    )
    draw_template_text(
        draw,
        fonts,
        f"{values['senderName']}  {values['senderMobile']} {values['senderAddressShort']}",
        9.97,
        63.34,
        58.82,
        4.52,
        size=2.8,
        wrap=True,
        valign="middle",
    )
    draw_template_text(
        draw,
        fonts,
        "本次服务适用中通官网(www.zto.com)公示的快递服务协议条款。您对此单的签收代表您已收到快件且包装完好无损。",
        5.42,
        68.68,
        27.38,
        6.61,
        size=1.8,
        wrap=True,
    )
    draw_code128(draw, values["waybillCode"], 34.51, 68.8, 32.86, 6.91, show_text=False)

    if values["privacyNumber"]:
        draw_template_text(draw, fonts, "虚拟号码", 5.55, 45.51, 14.69, 4.48, size=3.2, fill="white", background="black", bold=True, align="center", valign="middle")
        draw_template_text(draw, fonts, values["privacyNumber"], 20.86, 45.3, 42.47, 4.81, size=4.3, bold=True, valign="middle")

    draw_template_text(draw, fonts, "已验视", 58.57, 101.39, 11, 3, size=2.6)
    draw_custom_area(draw, fonts, custom_data, custom, 0.1, 76)
    draw_bottom_ad(image, data)


def build_template_values(data: dict[str, Any], document_id: str, page_no: int, page_count: int) -> dict[str, str]:
    routing = data.get("routingInfo") if isinstance(data.get("routingInfo"), dict) else {}
    sortation = routing.get("sortation") if isinstance(routing.get("sortation"), dict) else {}
    consolidation = routing.get("consolidation") if isinstance(routing.get("consolidation"), dict) else {}
    sender = data.get("sender") if isinstance(data.get("sender"), dict) else {}
    recipient = data.get("recipient") if isinstance(data.get("recipient"), dict) else {}
    sender_address = sender.get("address") if isinstance(sender.get("address"), dict) else {}
    recipient_address = recipient.get("address") if isinstance(recipient.get("address"), dict) else {}
    extra = data.get("extraInfo") if isinstance(data.get("extraInfo"), dict) else {}

    route_code = text(routing.get("routeCode"))
    new_block_code = text(routing.get("newBlockCode"))
    datoubi = " ".join(part for part in [text(sortation.get("name")), route_code, new_block_code] if part).strip()
    block_code = text(routing.get("blockCode"))
    secret_mobile = text(recipient.get("secretConsigneeMobile"))
    privacy_number = secret_mobile.replace("-", "转") if secret_mobile else ""
    now = time.localtime()
    return {
        "waybillCode": text(data.get("waybillCode")) or document_id,
        "yyyyMMdd": time.strftime("%Y/%m/%d", now),
        "hhmmss": time.strftime("%H:%M:%S", now),
        "docSeqText": f"{page_no}/{page_count}",
        "datoubi": datoubi,
        "consolidation": text(consolidation.get("name")),
        "blockCode": block_code,
        "prefixCode": "驿" if text(extra.get("staDoorHome")) == "true" else "末",
        "privacyNumber": privacy_number,
        "recipientName": text(recipient.get("name")),
        "recipientMobile": text(recipient.get("mobile") or recipient.get("phone")),
        "recipientAddress": format_address(recipient_address),
        "senderName": text(sender.get("name")),
        "senderMobile": text(sender.get("mobile") or sender.get("phone")),
        "senderAddressShort": format_address(sender_address, include_province=False),
    }


def draw_custom_area(
    draw: ImageDraw.ImageDraw,
    fonts: "FontBook",
    custom_data: dict[str, Any],
    custom: dict[str, Any],
    left_mm: float,
    top_mm: float,
) -> None:
    draw_template_text(
        draw,
        fonts,
        text(custom_data.get("ITEM_INFO") if custom_data.get("showItemInfo", True) else custom_data.get("PAGE_PRINT_TIPS")),
        left_mm,
        top_mm,
        74.757,
        21,
        size=float_or_default(custom_data.get("itemInfoFontSize"), 2.8) * 0.55,
        bold=True,
        wrap=True,
    )
    draw_template_text(
        draw,
        fonts,
        text(custom_data.get("SELLER_MEMO")),
        left_mm,
        top_mm + 21,
        30,
        9,
        size=2.7,
        wrap=True,
    )
    draw_template_text(
        draw,
        fonts,
        text(custom_data.get("BUYER_MEMO")),
        left_mm + 29.514,
        top_mm + 21,
        30,
        9,
        size=2.7,
        wrap=True,
    )
    draw_template_text(
        draw,
        fonts,
        text(custom_data.get("ITEM_TOTAL_COUNT")),
        left_mm + 59.272,
        top_mm + 21,
        15,
        9,
        size=7.4,
        fill=(128, 128, 128),
        bold=True,
        align="center",
        valign="middle",
    )


def draw_bottom_ad(image: Image.Image, data: dict[str, Any]) -> None:
    ads = data.get("adsInfo") if isinstance(data.get("adsInfo"), dict) else {}
    url = text(ads.get("miniBannerUrl"))
    if not url:
        return
    path = cache_path_for_url(url)
    if not path.exists():
        return
    try:
        with Image.open(path) as img:
            img = img.convert("RGBA")
            target_w = mm_px(58)
            ratio = target_w / max(img.width, 1)
            target_h = int(img.height * ratio)
            img = img.resize((target_w, target_h))
            image.paste(img, (mm_px(4.2), mm_px(110.4)), img if img.mode == "RGBA" else None)
    except Exception:
        return


def draw_debug_footer(
    draw: ImageDraw.ImageDraw,
    fonts: "FontBook",
    request_id: str,
    task_id: str,
    task: dict[str, Any],
    standard: dict[str, Any],
    custom: dict[str, Any],
) -> None:
    footer = f"Tabooprint task={short(task_id, 14)} printer={task.get('printer', '-')}"
    draw.text((mm_px(5.4), mm_px(123.2)), footer, fill=(110, 110, 110), font=fonts.font(9))


def should_draw_debug_footer() -> bool:
    return False


def draw_template_text(
    draw: ImageDraw.ImageDraw,
    fonts: "FontBook",
    value: str,
    left: float,
    top: float,
    width: float,
    height: float,
    size: float = 3,
    fill: tuple[int, int, int] | str = "black",
    background: tuple[int, int, int] | str | None = None,
    bold: bool = False,
    align: str = "left",
    valign: str = "top",
    wrap: bool = False,
) -> None:
    x = mm_px(left)
    y = mm_px(top)
    w = mm_px(width)
    h = mm_px(height)
    if background:
        draw.rectangle([x, y, x + w, y + h], fill=background)
    if not value:
        return
    font = fonts.font(max(8, int(size * PX_PER_MM * 0.72)))
    lines = value.splitlines()
    if wrap:
        wrapped: list[str] = []
        for line in lines:
            wrapped.extend(wrap_text(draw, line, w - 2, font))
        lines = wrapped
    line_h = text_height(draw, font) + 1
    max_lines = max(1, h // max(line_h, 1))
    lines = lines[:max_lines]
    total_h = len(lines) * line_h
    if valign == "middle":
        ty = y + max(0, (h - total_h) // 2)
    elif valign == "bottom":
        ty = y + max(0, h - total_h)
    else:
        ty = y
    for line in lines:
        line_w = int(draw.textlength(line, font=font))
        if align == "center":
            tx = x + max(0, (w - line_w) // 2)
        elif align == "right":
            tx = x + max(0, w - line_w)
        else:
            tx = x
        draw.text((tx, ty), line, fill=fill, font=font)
        if bold:
            draw.text((tx + 1, ty), line, fill=fill, font=font)
        ty += line_h


def draw_rotated_text(image: Image.Image, fonts: "FontBook", value: str, left: float, top: float, angle: int, size: float = 3) -> None:
    value = text(value)
    if not value:
        return
    font = fonts.font(max(8, int(size * PX_PER_MM * 0.72)))
    measure = Image.new("RGBA", (1, 1), (255, 255, 255, 0))
    measure_draw = ImageDraw.Draw(measure)
    bbox = measure_draw.textbbox((0, 0), value, font=font)
    text_img = Image.new("RGBA", (bbox[2] - bbox[0] + 4, bbox[3] - bbox[1] + 4), (255, 255, 255, 0))
    td = ImageDraw.Draw(text_img)
    td.text((2, 2), value, fill="black", font=font)
    rotated = text_img.rotate(angle, expand=True)
    image.paste(rotated, (mm_px(left), mm_px(top)), rotated)


def draw_code128(
    draw: ImageDraw.ImageDraw,
    value: str,
    left: float,
    top: float,
    width: float,
    height: float,
    show_text: bool = True,
) -> None:
    value = text(value)
    if not value:
        return
    x = mm_px(left)
    y = mm_px(top)
    w = mm_px(width)
    h = mm_px(height)
    bar_h = max(8, h - (14 if show_text else 0))
    pattern = code128_pattern(value)
    module_w = max(1, w // max(len(pattern), 1))
    barcode_w = min(w, module_w * len(pattern))
    start_x = x + max(0, (w - barcode_w) // 2)
    cursor = start_x
    for bit in pattern:
        if bit == "1":
            draw.rectangle([cursor, y, cursor + module_w - 1, y + bar_h], fill="black")
        cursor += module_w
    if show_text:
        font = FontBook().font(16)
        text_w = int(draw.textlength(value, font=font))
        draw.text((x + max(0, (w - text_w) // 2), y + h - 14), value, fill="black", font=font)


CODE128_PATTERNS = [
    "11011001100", "11001101100", "11001100110", "10010011000", "10010001100", "10001001100",
    "10011001000", "10011000100", "10001100100", "11001001000", "11001000100", "11000100100",
    "10110011100", "10011011100", "10011001110", "10111001100", "10011101100", "10011100110",
    "11001110010", "11001011100", "11001001110", "11011100100", "11001110100", "11101101110",
    "11101001100", "11100101100", "11100100110", "11101100100", "11100110100", "11100110010",
    "11011011000", "11011000110", "11000110110", "10100011000", "10001011000", "10001000110",
    "10110001000", "10001101000", "10001100010", "11010001000", "11000101000", "11000100010",
    "10110111000", "10110001110", "10001101110", "10111011000", "10111000110", "10001110110",
    "11101110110", "11010001110", "11000101110", "11011101000", "11011100010", "11011101110",
    "11101011000", "11101000110", "11100010110", "11101101000", "11101100010", "11100011010",
    "11101111010", "11001000010", "11110001010", "10100110000", "10100001100", "10010110000",
    "10010000110", "10000101100", "10000100110", "10110010000", "10110000100", "10011010000",
    "10011000010", "10000110100", "10000110010", "11000010010", "11001010000", "11110111010",
    "11000010100", "10001111010", "10100111100", "10010111100", "10010011110", "10111100100",
    "10011110100", "10011110010", "11110100100", "11110010100", "11110010010", "11011011110",
    "11011110110", "11110110110", "10101111000", "10100011110", "10001011110", "10111101000",
    "10111100010", "11110101000", "11110100010", "10111011110", "10111101110", "11101011110",
    "11110101110", "11010000100", "11010010000", "11010011100", "1100011101011",
]


def code128_pattern(value: str) -> str:
    if value.isdigit() and len(value) >= 2:
        if len(value) % 2:
            value = "0" + value
        codes = [105]
        codes.extend(int(value[index:index + 2]) for index in range(0, len(value), 2))
    else:
        codes = [104]
        codes.extend(max(0, min(95, ord(char) - 32)) for char in value)
    checksum = codes[0]
    for index, code in enumerate(codes[1:], start=1):
        checksum += index * code
    codes.append(checksum % 103)
    codes.append(106)
    return "".join(CODE128_PATTERNS[code] for code in codes)


def draw_cached_image(image: Image.Image, url: str, left: float, top: float, width: float, height: float) -> None:
    path = cache_path_for_url(url)
    if not path.exists():
        return
    try:
        with Image.open(path) as img:
            img = img.convert("RGBA").resize((mm_px(width), mm_px(height)))
            image.paste(img, (mm_px(left), mm_px(top)), img)
    except Exception:
        return


def cache_path_for_url(url: str) -> Path:
    return CAINIAO_CACHE_DIR / hashlib.md5(url.encode("utf-8")).hexdigest()


def format_address(address: dict[str, Any], include_province: bool = True) -> str:
    keys = ["province", "city", "district", "town", "detail"] if include_province else ["city", "district", "town", "detail"]
    return "".join(text(address.get(key)) for key in keys)


def mm_px(value: float) -> int:
    return int(round(float(value) * PX_PER_MM))


def float_or_default(value: Any, default: float) -> float:
    try:
        return float(value)
    except Exception:
        return default


def wrap_text(draw: ImageDraw.ImageDraw, value: str, width: int, font: ImageFont.ImageFont) -> list[str]:
    value = re.sub(r"\s+", " ", text(value)).strip()
    if not value:
        return [""]
    lines: list[str] = []
    current = ""
    for char in value:
        candidate = current + char
        if draw.textlength(candidate, font=font) > width and current:
            lines.append(current)
            current = char
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def text_height(draw: ImageDraw.ImageDraw, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), "Ag中文", font=font)
    return max(1, bbox[3] - bbox[1])


class FontBook:
    def __init__(self) -> None:
        self.path = self._find_font()
        self.cache: dict[int, ImageFont.ImageFont] = {}

    def font(self, size: int) -> ImageFont.ImageFont:
        if size not in self.cache:
            self.cache[size] = ImageFont.truetype(self.path, size)
        return self.cache[size]

    @staticmethod
    def _find_font() -> str:
        for path in FONT_PATHS:
            if Path(path).exists():
                return path
        return "/System/Library/Fonts/Supplemental/AppleGothic.ttf"


def text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    return str(value)


def short(value: Any, size: int = 18) -> str:
    raw = text(value)
    if len(raw) <= size:
        return raw
    return f"{raw[: size - 5]}...{raw[-2:]}"


def document_ids(payload: dict[str, Any]) -> list[str]:
    task = payload.get("task") or {}
    docs = task.get("documents") if isinstance(task.get("documents"), list) else []
    return [text(doc.get("documentID") or doc.get("documentId")) for doc in docs if isinstance(doc, dict)]


def safe_filename(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("._")
    return safe or f"waybill_{int(time.time() * 1000)}"


if __name__ == "__main__":
    raise SystemExit(main())
