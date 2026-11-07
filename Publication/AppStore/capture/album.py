"""Generate original nursery illustrations as App Store fixture image assets."""
import json
import pathlib
import subprocess
import sys

SCENES = [
    ("#ead7c4", "#b17b5e", """
      <g fill="#ae7859" stroke="#8a563f" stroke-width="5">
        <circle cx="230" cy="237" r="54"/><circle cx="490" cy="237" r="54"/>
        <ellipse cx="360" cy="475" rx="132" ry="111"/>
        <ellipse cx="250" cy="526" rx="60" ry="40"/><ellipse cx="470" cy="526" rx="60" ry="40"/>
        <circle cx="360" cy="335" r="149"/>
      </g>
      <g fill="#d49a7d"><circle cx="230" cy="237" r="33"/><circle cx="490" cy="237" r="33"/></g>
      <ellipse cx="360" cy="385" rx="67" ry="51" fill="#e5b99a"/>
      <g fill="#442b26"><circle cx="305" cy="327" r="10"/><circle cx="414" cy="327" r="10"/>
      <path d="M340 368q20-13 40 0q-1 23-20 24q-19-1-20-24z"/></g>
      <path d="M360 390v12m-17-4q17 22 34 0" fill="none" stroke="#442b26" stroke-width="4" stroke-linecap="round"/>
      <path d="M358 480l-50-26v56l50-26 50 26v-56z" fill="#a394c8"/>
      <circle cx="360" cy="482" r="11" fill="#8270a5"/>
    """),
    ("#d8d2ee", "#9889be", """
      <path d="M360 102v72m-194 56q194-111 388 0M191 217v156m169-198v209m169-166v143" fill="none"
      stroke="#7a648f" stroke-width="6" stroke-linecap="round"/>
      <path d="M188 333l13 26 29 4-21 20 5 30-26-14-27 14 5-30-21-20 29-4z" fill="#f9dd91"/>
      <path d="M388 378a77 77 0 1 0 54 111 67 67 0 0 1-54-111z" fill="#f9e6a8"/>
      <path d="M526 346l14 27 29 4-21 20 5 29-27-14-26 14 5-29-21-20 29-4z" fill="#fff8e9"/>
      <circle cx="174" cy="476" r="7" fill="#fbf0ce"/><circle cx="530" cy="480" r="7" fill="#fbf0ce"/>
    """),
    ("#dce3d1", "#92a980", """
      <g>
      <circle cx="360" cy="360" r="149" fill="none" stroke="#b97559" stroke-width="34"/>
      <circle cx="360" cy="205" r="57" fill="#e6b08d"/><circle cx="492" cy="278" r="46" fill="#ac99ca"/>
      <circle cx="230" cy="278" r="46" fill="#e4ca85"/><circle cx="485" cy="449" r="42" fill="#9cb185"/>
      <circle cx="238" cy="450" r="45" fill="#d5957f"/><circle cx="359" cy="512" r="51" fill="#f4deba"/>
      </g>
    """),
    ("#f0d8cb", "#d19383", """
      <g>
      <path d="M125 270q126-50 235 35q109-85 235-35v255q-124-47-235 37q-111-84-235-37z" fill="#a78eb5"/>
      <path d="M147 251q118-41 213 42q95-83 213-42v251q-122-31-213 43q-91-74-213-43z" fill="#fcf0d8"/>
      <path d="M360 295v244" stroke="#d8baa2" stroke-width="4"/>
      <path d="M194 335q54-8 117 26m-117 18q54-8 117 25m-117 19q54-8 117 25" fill="none"
      stroke="#d8baa2" stroke-width="6" stroke-linecap="round"/>
      <path d="M492 322a53 53 0 1 0 31 81 49 49 0 0 1-31-81z" fill="#d4ac59"/>
      <circle cx="510" cy="350" r="7" fill="#d4ac59"/>
      </g>
    """),
]

assets = pathlib.Path(sys.argv[1])
for index, (background, accent, art) in enumerate(SCENES):
    directory = assets / f"StorefrontAlbum{index}.imageset"
    directory.mkdir(exist_ok=True)
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="720" height="720" viewBox="0 0 720 720">
      <rect width="720" height="720" fill="{background}"/>
      <circle cx="360" cy="320" r="305" fill="#fff8ed" opacity=".31"/>
      <circle cx="360" cy="320" r="265" fill="#fff8ed" opacity=".28"/>
      <ellipse cx="360" cy="586" rx="215" ry="53" fill="{accent}" opacity=".18"/>
      {art}
      <g fill="{accent}" opacity=".42">
        <circle cx="95" cy="125" r="4"/><circle cx="603" cy="553" r="6"/><circle cx="628" cy="176" r="4"/>
        <path d="M112 464v26m-13-13h26M610 298v24m-12-12h24" stroke="{accent}" stroke-width="3" stroke-linecap="round"/>
      </g>
    </svg>"""
    subprocess.run(["magick", "-background", "none", "svg:-", str(directory / "illustration.png")],
                   input=svg.encode(), check=True)
    (directory / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "illustration.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }))
