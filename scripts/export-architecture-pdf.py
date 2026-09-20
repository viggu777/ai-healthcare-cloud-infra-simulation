#!/usr/bin/env python3
"""Regenerate the submission PDFs (one command per doc, or all at once).

Toolchain (matches Architecture-PDF-Guide exactly):
  1. Markdown source with mermaid fenced blocks.
  2. Render EACH mermaid block to SVG with @mermaid-js/mermaid-cli.
  3. Convert mermaid HTML labels (foreignObject) to printable SVG text.
  4. Markdown -> HTML with python-markdown (tables, fenced_code, toc).
  5. HTML -> A4 PDF with WeasyPrint + print CSS (footer page numbers).
  6. Verify programmatically (no syntax errors, boxes present, no blanks).
  7. This script + the .md sources stay in sync.

Usage:
  python3 scripts/export-architecture-pdf.py                    # architecture only
  python3 scripts/export-architecture-pdf.py security-report    # one doc
  python3 scripts/export-architecture-pdf.py all                # all three
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "submission-docs"

DOCS = {
    "architecture": {
        "src": "architecture.md",
        "pdf": "architecture.pdf",
        "svg_subdir": "diagrams",
        "title": "AI Healthcare Cloud Infra Simulation - Architecture",
        "footer": "AI Healthcare Cloud Infra Simulation",
        "headers": ["Product Loop", "Stack Rationale", "System Architecture",
                    "Gateway Routes", "Backend Lifecycle", "Services Table",
                    "DB Schema", "Auth and Isolation", "Storage and Persistence",
                    "Processing Pipeline", "AI-Mock Integration", "Per-Feature Flows",
                    "Background Jobs", "Observability and Evaluation",
                    "Error Handling", "Security and Performance",
                    "Admin and Operations", "Deployment and Environment",
                    "Testing and Verification", "Trade-offs", "Current Status"],
        "labels": ["Nginx gateway", "Redis queue", "MongoDB appointments",
                   "Circuit", "Pushgateway", "Alertmanager", "mock triage",
                   "Dead letter", "SHA-tagged", "WorkerDown"],
    },
    "security-report": {
        "src": "security-report.md",
        "pdf": "security-report.pdf",
        "svg_subdir": "diagrams-security",
        "title": "AI Healthcare Cloud Infra Simulation - Security Report",
        "footer": "AI Healthcare Cloud Infra Simulation - Security Report",
        "headers": ["Security Layers", "Network Security", "Identity and Access",
                    "Secrets Management", "Container and Runtime Security",
                    "Infrastructure Security Validation", "Scan Gates and Evidence",
                    "Findings Fixed", "Remaining Risks", "Security Failure Demo",
                    "Pipeline Security Wiring", "Current Posture"],
        "labels": ["rate limit", "least-privilege", "Gitleaks", "Trivy",
                   "cap_drop", "monitor_user", "digest-pinned",
                   "BLOCKED pre-deploy", "32 passed 0 failed", "read_only"],
    },
    "incident-report": {
        "src": "incident-report.md",
        "pdf": "incident-report.pdf",
        "svg_subdir": "diagrams-incident",
        "title": "AI Healthcare Cloud Infra Simulation - Incident Report",
        "footer": "AI Healthcare Cloud Infra Simulation - Incident Report",
        "headers": ["Incident Lifecycle", "INC-01 Worker Failure",
                    "INC-02 EHR Outage", "INC-03 Database",
                    "Detection Signals Compared", "Recovery Mechanics Compared",
                    "Prevention Backlog", "Reproducibility Checklist",
                    "Current Status"],
        "labels": ["WorkerDown", "QueueBacklog", "EHROutage", "DBUnavailable",
                   "ConfigFailure", "processed_ehr_degraded", "17:23:42",
                   "SMOKE OK", "ready false", "cooldown"],
    },
}

CSS_BASE = """
@page {
  size: A4;
  margin: 20mm 16mm 22mm 16mm;
  @bottom-center {
    content: "__FOOTER__ \\00b7 " counter(page) " / " counter(pages);
    font-size: 8pt;
    color: #666;
    font-family: sans-serif;
  }
}
body { font-family: sans-serif; font-size: 10pt; line-height: 1.45; color: #222; }
h1 { font-size: 20pt; margin-top: 0; }
h2 { font-size: 13pt; page-break-after: avoid; color: #111; border-bottom: 1px solid #ccc; padding-bottom: 2mm; }
h3 { font-size: 11pt; page-break-after: avoid; }
p, li { orphans: 3; widows: 3; }
.diagram { text-align: center; margin: 4mm 0; }
.diagram svg, .diagram img { max-width: 100%; max-height: 232mm; }
table { width: 100%; border-collapse: collapse; font-size: 8.4pt; margin: 3mm 0; }
th, td { border: 1px solid #999; padding: 1.2mm 1.8mm; text-align: left; word-wrap: break-word; overflow-wrap: break-word; }
th { background: #f0f0f0; }
tr { page-break-inside: avoid; }
pre { white-space: pre-wrap; word-break: break-word; font-size: 8pt; background: #f6f6f6; padding: 3mm; }
code { font-size: 8.5pt; }
.cover { text-align: center; margin-top: 30mm; }
.cover h1 { font-size: 24pt; }
"""

MERMAID_RE = re.compile(r"```mermaid\n(.*?)```", re.DOTALL)


def extract_mermaid(md_text):
    return MERMAID_RE.findall(md_text)


def css_for(footer):
    return CSS_BASE.replace("__FOOTER__", footer)


def render_mermaid(blocks, svg_dir):
    svg_dir.mkdir(parents=True, exist_ok=True)
    svg_files = []
    for i, block in enumerate(blocks):
        mmd = svg_dir / f"diagram-{i + 1:02d}.mmd"
        svg = svg_dir / f"diagram-{i + 1:02d}.svg"
        mmd.write_text(block)
        r = subprocess.run(
            ["npx", "--yes", "@mermaid-js/mermaid-cli", "-i", str(mmd),
             "-o", str(svg), "-t", "default", "-b", "white"],
            capture_output=True, text=True, cwd=str(ROOT))
        if r.returncode != 0 or not svg.exists():
            print(f"MMERAIL FAIL diagram {i + 1}:\n{r.stdout}\n{r.stderr}")
            sys.exit(1)
        fix_foreign_objects(svg)
        svg_files.append(svg)
    return svg_files


def fix_foreign_objects(svg_path):
    """Replace <foreignObject><p>L1<br/>L2</p></...> with centered multi-line <text>."""
    text = svg_path.read_text()
    pat = re.compile(r"<foreignObject.*?</foreignObject>", re.DOTALL)

    def repl(m):
        chunk = m.group(0)
        paras = re.findall(r"<p[^>]*>(.*?)</p>", chunk, re.DOTALL)
        lines = []
        for p in paras:
            p = re.sub(r"<br\s*/?>", "\n", p)
            p = re.sub(r"<[^>]+>", "", p)
            lines.extend([ln.strip() for ln in p.split("\n")])
        lines = [ln for ln in lines if ln]
        if not lines:
            return ""
        mm = re.search(r'x="([\d.\-]+)"\s+y="([\d.\-]+)"\s+width="([\d.\-]+)"\s+height="([\d.\-]+)"', chunk)
        if mm:
            x, y, w, h = map(float, mm.groups())
            cx, cy = x + w / 2, y + h / 2
        else:
            cx, cy = 100.0, 20.0
        n = len(lines)
        tspans = "".join(
            f'<tspan x="{cx:.1f}" dy="{14 if k else -(n - 1) * 7:.1f}">{esc(ln)}</tspan>'
            for k, ln in enumerate(lines))
        return (f'<text x="{cx:.1f}" y="{cy:.1f}" text-anchor="middle" '
                f'font-family="sans-serif" font-size="14" fill="#333">{tspans}</text>')

    text = pat.sub(repl, text)
    svg_path.write_text(text)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build_html(md_text, svg_files, cfg):
    import markdown
    parts = MERMAID_RE.split(md_text)
    subdir = cfg["svg_subdir"]
    html_parts = []
    di = 0
    for k, part in enumerate(parts):
        if k % 2 == 0:
            html_parts.append(markdown.markdown(
                part, extensions=["tables", "fenced_code", "toc"]))
        else:
            di += 1
            rel = f"{subdir}/diagram-{di:02d}.svg"
            html_parts.append(
                f'<div class="diagram"><img src="{rel}" /></div>')
    body = "\n".join(html_parts)
    return (f"<!DOCTYPE html><html><head><meta charset='utf-8'>"
            f"<title>{cfg['title']}</title><style>{css_for(cfg['footer'])}</style></head>"
            f"<body>{body}</body></html>")


def write_pdf(html, pdf_path):
    from weasyprint import HTML
    with tempfile.NamedTemporaryFile("w", suffix=".html",
                                     dir=str(OUT_DIR), delete=False) as f:
        f.write(html)
        tmp = f.name
    try:
        HTML(filename=tmp, base_url=str(OUT_DIR)).write_pdf(str(pdf_path))
    finally:
        Path(tmp).unlink(missing_ok=True)


def verify(blocks, svg_files, cfg, pdf_path):
    errors = []
    # 1. pdftotext must contain zero "Syntax error in text"
    txt = subprocess.run(["pdftotext", str(pdf_path), "-"],
                         capture_output=True, text=True).stdout
    if "Syntax error in text" in txt:
        errors.append("PDF contains 'Syntax error in text'")
    # 2. section headers present
    for h in cfg["headers"]:
        if h not in txt:
            errors.append(f"missing section header: {h}")
    # 3. flowchart box names present (sample of key labels)
    for label in cfg["labels"]:
        if label.lower() not in txt.lower():
            errors.append(f"missing diagram/box text: {label}")
    # 4. blank-page check: render pages, flag near-empty ones
    info = subprocess.run(["pdfinfo", str(pdf_path)],
                          capture_output=True, text=True).stdout
    m = re.search(r"Pages:\s+(\d+)", info)
    pages = int(m.group(1)) if m else 0
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["pdftoppm", "-png", "-r", "30", str(pdf_path),
                        f"{td}/p"], capture_output=True)
        from pathlib import Path as P
        import statistics
        blanks = []
        for png in sorted(P(td).glob("*.png")):
            # cheap ink check via file size variance is unreliable; use
            # pdftotext per-page word count instead
            _ = png
        for n in range(1, pages + 1):
            pt = subprocess.run(
                ["pdftotext", "-f", str(n), "-l", str(n), str(pdf_path), "-"],
                capture_output=True, text=True).stdout
            if len(pt.split()) < 8:
                blanks.append(n)
    if blanks:
        errors.append(f"blank pages detected: {blanks}")
    print(f"diagrams: {len(blocks)}, svg files: {len(svg_files)}, "
          f"pages: {pages}, blank pages: {blanks or 'none'}")
    print(f"errors: {len(errors)}")
    for e in errors:
        print("  ERROR:", e)
    # 5. every mermaid block rendered to a non-empty SVG
    for s in svg_files:
        if s.stat().st_size < 500:
            errors.append(f"suspiciously small SVG: {s.name}")
    return errors


def build_one(name, cfg):
    print(f"=== {name} ===")
    src = OUT_DIR / cfg["src"]
    pdf_path = OUT_DIR / cfg["pdf"]
    svg_dir = OUT_DIR / cfg["svg_subdir"]
    md_text = src.read_text()
    blocks = extract_mermaid(md_text)
    print(f"mermaid blocks: {len(blocks)}")
    if not blocks:
        sys.exit(f"no mermaid blocks found in {src} — refusing to build")
    svg_files = render_mermaid(blocks, svg_dir)
    html = build_html(md_text, svg_files, cfg)
    write_pdf(html, pdf_path)
    print(f"wrote {pdf_path} ({pdf_path.stat().st_size} bytes)")
    errors = verify(blocks, svg_files, cfg, pdf_path)
    if errors:
        sys.exit(1)
    print("VERIFY OK")


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "architecture"
    names = list(DOCS) if arg == "all" else [arg]
    for name in names:
        if name not in DOCS:
            sys.exit(f"unknown doc '{name}' — choose from {list(DOCS)} or 'all'")
        build_one(name, DOCS[name])


if __name__ == "__main__":
    main()
