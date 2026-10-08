extends RefCounted

# Original vector pictograms; kept separate from simulation and imported assets.
const PATHS := {
	"overview": '<path d="M4 22V10l6-4v16m4 0V3h7v19M2 22h22M16 7h3m-3 5h3m-3 5h3"/>',
	"roads": '<path d="M5 23 8 1m11 22L16 1M12 3v4m0 4v4m0 4v3"/>',
	"transport": '<rect x="5" y="3" width="14" height="17" rx="3"/><path d="M5 12h14M8 20v3m8-3v3M8 7h8"/><circle cx="8" cy="16" r="1"/><circle cx="16" cy="16" r="1"/>',
	"terrain": '<path d="m2 21 8-14 5 8 3-5 6 11H2Zm5-7 3 2 3-2M18 3v4m-2-2h4"/>',
	"economy": '<path d="M3 22V12h4v10m3 0V7h4v15m3 0V2h4v20M2 22h22"/>',
	"residents": '<circle cx="9" cy="7" r="4"/><path d="M2 22v-4a7 7 0 0 1 14 0v4m2-18a4 4 0 0 1 0 8m1 3a5 5 0 0 1 4 5v2"/>',
	"saves": '<path d="M3 3h15l3 3v16H3V3Zm4 0v7h10V3M7 22v-8h10v8"/>',
}

const COLORS := {
	"overview": "#76cdbb",
	"roads": "#f0b75c",
	"transport": "#78adf5",
	"terrain": "#91c978",
	"economy": "#e58c6d",
	"residents": "#c69ae5",
	"saves": "#9aafc4",
}

static func texture(key: String) -> Texture2D:
	var body := str(PATHS.get(key, PATHS["overview"]))
	var color := str(COLORS.get(key, COLORS["overview"]))
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 26 26"><g fill="none" stroke="%s" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>' % [color, body]
	var image := Image.new()
	if image.load_svg_from_string(svg) != OK:
		return null
	return ImageTexture.create_from_image(image)
