import re
import unicodedata

# RFC 7541 Appendix B static Huffman table extractor.
# Produces Swift tuples "(code, bitLength, byteValue)" for HPACKHuffman.swift.
# Handles both row formats used by the RFC: "( 32)  ..." and "' ' ( 32)  ...".

rfc = open("/tmp/rfc7541.txt", encoding="utf-8").read()
start = rfc.index("(  0)  |11111111|11000")
seg = rfc[start:]

pat = re.compile(r"\(\s*(\d+)\)\s+\|([01|]+)\s+([0-9a-f]+)\s+\[\s*(\d+)\]")
eos_pat = re.compile(r"EOS\s+\|([01|]+)\s+([0-9a-f]+)\s+\[\s*(\d+)\]")

entries = []
for line in seg.split("\n"):
    s = unicodedata.normalize("NFKC", line).strip()
    m = pat.search(s)
    if m:
        entries.append((int(m.group(1)), int(m.group(3), 16), int(m.group(4))))
        continue
    m2 = eos_pat.search(s)
    if m2:
        entries.append((256, int(m2.group(2), 16), int(m2.group(3))))

assert len(entries) == 257, "expected 257 symbols, got %d" % len(entries)
assert entries[0] == (0, 0x1FF8, 13)
assert entries[47] == (47, 0x18, 6)
assert entries[256] == (256, 0x3FFFFFFF, 30)

for sym, code, ln in entries:
    # Codes are MSB-aligned and may have leading zero bits, so only the range is checkable.
    assert code < (1 << ln), (sym, hex(code), ln)

lines = []
for sym, code, ln in entries:
    if sym == 256:
        continue  # EOS is handled implicitly by the decoder's padding check.
    lines.append("        (0x%x, %d, %d)," % (code, ln, sym))

src_path = "/var/minis/workspace/Vulpine/Vulpine/Tunnel/HPACKHuffman.swift"
src = open(src_path).read()
marker = "        HPACK_TABLE\n"
assert marker in src, "HPACK_TABLE marker missing from HPACKHuffman.swift"
src = src.replace(marker, "\n".join(lines) + "\n")
open(src_path, "w").write(src)
print("injected %d huffman symbols" % (len(entries) - 1))
