# Font notice corrections for this candidate

This note corrects summary metadata without changing fonts or retained upstream
license/provenance bytes. It describes only the exact historical inputs bundled
here; it does not classify newer Cubic 11 releases.

The Cubic 11 source font pinned by both DeparturePixelZh and the Doto mixed
families is SHA-256 `0193f5f033612496df6b45ee92ac3b335bc6a5a24ff95da55ca87b33e57dcf62`,
at upstream revision `4c566f7d6cc5c05ee360fe9cff56b5da1fcafd4d`. The retained
DeparturePixelZh provenance records its embedded version as **1.451**. The
producer NOTICE's “Cubic 11 1.500” label is incorrect for this pin; 1.500 is
Departure Mono's version, not this Cubic input's version.

The exact pinned upstream license is at the repository root:
https://raw.githubusercontent.com/ACh-K/Cubic-11/4c566f7d6cc5c05ee360fe9cff56b5da1fcafd4d/OFL.txt

Retrieved and byte-compared on 2026-10-22: 5,364 bytes, SHA-256
`2b6e5938e5cffa0b9e183bd05f8c363e174e7ebed1a0556e2855fd1707fa2188`.
It includes the Cubic/M+ permissive and Chinese inherited-license paragraphs
followed by the full SIL OFL 1.1 text. The retained license files in this
candidate match it exactly. Preserve the whole text, not just an SPDX label.
A provenance URL ending `fonts/ttf/OFL.txt` is a historical location error
(404 at this pinned revision); the root URL above is the verified location.
The original provenance is retained as an immutable historical build record,
not silently rewritten to pretend the producer used a different source.

The Font Logos 1.3.0 tag resolves to upstream commit
`e92426e28ee5bbf4ca328b33e3a393b7a5045f01`. Its LICENSE matches the
bundled `Dependencies/DeparturePixelZh/Licenses/FontLogos.txt` byte for byte
(SHA-256 `88d9b4eb60579c191ec391ca04c16130572d7eedc4a86daa58bf28c6e14c9bcd`):
https://github.com/lukas-w/font-logos/blob/e92426e28ee5bbf4ca328b33e3a393b7a5045f01/LICENSE
The same Font Logos version's package metadata also explicitly says `Unlicense`:
https://github.com/lukas-w/font-logos/blob/e92426e28ee5bbf4ca328b33e3a393b7a5045f01/package.json
The pinned Nerd Fonts 3.5.1 glyph inventory separately calls it “unlicensed”;
both upstream statements are preserved rather than treated as identical:
https://github.com/ryanoasis/nerd-fonts/blob/b894ea7803af6aade63d60a4381e006098ec9c4d/src/glyphs/README.md
The Font Logos README says brand glyphs are their owners' trademarks and should
represent their respective products. The copyright license is not trademark
permission; these notices do not establish rights to use every logo as a brand.

Font summaries do not apply GPL or CC artwork terms to font software. Keep each
font's full inherited notices and source naming conditions. This correction is
not proof that other Cubic 11 revisions or current upstream terms are identical.

繁中：此候選固定 Cubic 11 輸入的內嵌版號為 1.451，不是舊摘要的 1.500。
已核對同一固定版本根目錄的 OFL.txt，完整原文與隨附檔相同；原始字型、授權及
provenance 保留不改。舊 provenance 的字型子目錄授權連結錯誤，以本註記的根目錄連結為準。
不推論其他版本，也不將程式／圖稿授權套用到字型。

简中：此候选固定 Cubic 11 输入的内嵌版本为 1.451，不是旧摘要的 1.500。
已核对同一固定版本根目录的 OFL.txt，完整原文与随附文件相同；原始字体、许可和
provenance 保留不改。旧 provenance 的字体子目录许可链接错误，以本说明的根目录链接为准。
不推论其他版本，也不将代码／图稿许可套用到字体。
