import Foundation

// From Bezzle/MCP/MCPDefinitions.swift, for Windows: the tools Bezzle on Windows has so far, as the
// assistant is told of them, in the Mac's words.

/// The tools as the assistant is told of them: each one's name, what it does, and what it takes.
extension MCPTools {
    func makeDefinitions() -> [Definition] {
        let design = ("design", Self.text("Which design: its name or path. Leave it out for the one in front; one not open is opened."))
        let layers = ("layers", Self.list("Layers by id, or by name (\"Artboard/Name\" when the name is on several). Leave it out for the selection."))
        let layerKinds = ["artboard", "carousel", "rectangle", "ellipse", "line", "text", "path", "group"]
        let newLayer: JSONValue = .object([
            ("type", "object"),
            ("properties", .object([
                ("kind", Self.choice(layerKinds, "What it is. A carousel is an artboard of slides side by side, exported a picture a slide.")),
                ("children", ["type": "array", "items": ["type": "object"],
                              "description": "For artboards and groups: the layers in it, bottom first, each like this one. A new group's layers are placed in its parent's coordinates, and it fits itself round them."]),
            ] + Self.layerProperties)),
            ("required", ["kind"]),
        ])
        let change: JSONValue = .object([
            ("type", "object"),
            ("properties", .object([
                ("layer", Self.text("The layer to change, by id or name.")),
                ("layers", Self.list("Several layers to change the same way, in place of layer.")),
            ] + Self.layerProperties)),
        ])

        return [
            Definition(name: "list_designs", title: "List designs",
                       description: "Lists the designs on Bezzle's home screen, the latest first, and which are open in windows.",
                       properties: [:], readOnly: true, run: { [unowned self] in try self.listDesigns($0) }),
            Definition(name: "create_design", title: "Create a design",
                       description: "Makes a new design in the Bezzle folder and opens it in a tab of its own. Give it a first artboard by preset, carousel format, or width and height; or none, for an empty canvas. Add more with add_layers.",
                       properties: .object([
                           ("name", Self.text("What the design is called; \"Untitled\" otherwise.")),
                           ("preset", Self.text("A first artboard of a preset size: \(Preset.all.map { "\($0.name) (\(Int($0.size.width))×\(Int($0.size.height)))" }.joined(separator: ", ")).")),
                           ("carousel", Self.text("A first artboard that is a carousel of this format: \(Carousel.formats.map(\.name).joined(separator: ", ")).")),
                           ("width", Self.number("A first artboard this wide.")),
                           ("height", Self.number("A first artboard this tall.")),
                       ]), run: { [unowned self] in try await self.createDesign($0) }),
            Definition(name: "open_design", title: "Open a design",
                       description: "Opens a design in a tab of its own, or brings its tab to the front. Opening an Adobe XD, Figma (.fig) or Sketch file brings it in as a new design.",
                       properties: .object([("design", Self.text("Its name, as list_designs gives it, or the path of a .bezzle, .vellum, .xd, .fig, .sketch, .psd or .psb file."))]),
                       required: ["design"], run: { [unowned self] in try await self.openDesign($0) }),
            Definition(name: "close_design", title: "Close a design",
                       description: "Closes a design's tab. It is saved; designs always are.",
                       properties: .object([design]), run: { [unowned self] in try await self.closeDesign($0) }),
            Definition(name: "get_design", title: "Get a design",
                       description: "What is in a design: its artboards and layers as a tree, bottom first, with ids, kinds, names, positions, sizes, fills and text; and what is selected, the zoom, and what Undo would undo. get_layers has everything about particular layers.",
                       properties: .object([
                           design,
                           ("layer", Self.text("Only this artboard or group and what is in it.")),
                           ("depth", Self.integer("How many levels down to list: 0 for only the artboards. Everything otherwise.")),
                       ]), readOnly: true, run: { [unowned self] in try await self.getDesign($0) }),
            Definition(name: "find_layers", title: "Find layers",
                       description: "Finds layers by part of their name, their kind, or their words.",
                       properties: .object([
                           design,
                           ("name", Self.text("Part of the name, in any case.")),
                           ("kind", Self.choice(Array(layerKinds.filter { $0 != "carousel" }), "Only layers of this kind.")),
                           ("text", Self.text("Text layers whose words have this in them.")),
                           ("within", Self.text("Only inside this artboard or group.")),
                       ]), readOnly: true, run: { [unowned self] in try await self.findLayers($0) }),
            Definition(name: "get_layers", title: "Get layers",
                       description: "Everything about some layers: where they are, fill, border, shadow, corners, font, blur, outline and the rest, in the form update_layers takes.",
                       properties: .object([design, layers, ("children", Self.boolean("With all they hold, for artboards and groups."))]),
                       readOnly: true, run: { [unowned self] in try await self.getLayers($0) }),
            Definition(name: "add_layers", title: "Add layers",
                       description: "Adds layers: artboards on the canvas, and anything else on an artboard, in a group, or loose on the canvas. Nest children to build a whole screen in one call; it is one step of the undo history. A layer not placed with x and y goes in the middle of its parent; a new artboard goes to the right of the others. The new layers are selected.",
                       properties: .object([
                           design,
                           ("parent", Self.text("The artboard or group they go in, or \"canvas\". The selection's artboard, or the one in view, otherwise. Artboards always go on the canvas.")),
                           ("index", Self.integer("Where among the parent's layers, counted from the bottom from 0. On top otherwise.")),
                           ("layers", ["type": "array", "items": newLayer, "description": "The layers to add, bottom first."]),
                       ]), required: ["layers"], run: { [unowned self] in try await self.addLayers($0) }),
            Definition(name: "update_layers", title: "Update layers",
                       description: "Changes layers: any of their properties, each update to one layer or several. All of it is one step of the undo history. Only what is given changes; objects such as border and font are merged into what is there.",
                       properties: .object([
                           design,
                           ("updates", ["type": "array", "items": change, "description": "Each a layer (or layers), and what to change on it. Without layer or layers, it changes the selection."]),
                       ]), required: ["updates"], run: { [unowned self] in try await self.updateLayers($0) }),
            Definition(name: "delete_layers", title: "Delete layers",
                       description: "Deletes layers, with all they hold.",
                       properties: .object([design, layers]), destructive: true, run: { [unowned self] in try await self.deleteLayers($0) }),
            Definition(name: "duplicate_layers", title: "Duplicate layers",
                       description: "Puts a copy of each layer just above it, offset a little; an artboard's copy goes beside it. The copies are selected.",
                       properties: .object([
                           design, layers,
                           ("dx", Self.number("How far right each copy goes; 10 otherwise.")),
                           ("dy", Self.number("How far down; 10 otherwise.")),
                       ]), run: { [unowned self] in try await self.duplicateLayers($0) }),
            Definition(name: "move_layers", title: "Move layers in the list",
                       description: "Moves layers to another artboard or group, or onto the canvas, and to a place among its layers. They keep where they are on the canvas; move them on it with update_layers' x and y.",
                       properties: .object([
                           design, layers,
                           ("parent", Self.text("The artboard or group they go in, or \"canvas\". Their own parent otherwise.")),
                           ("index", Self.integer("Where among its layers, counted from the bottom from 0. On top otherwise.")),
                       ]), run: { [unowned self] in try await self.moveLayers($0) }),
            Definition(name: "group_layers", title: "Group layers",
                       description: "Puts layers on one artboard, or all on the canvas, into a new group, in the artboard or group that holds them all, where the topmost of them was. Groups move and resize as one.",
                       properties: .object([design, layers, ("name", Self.text("The group's name; \"Group 1\" and so on otherwise."))]),
                       run: { [unowned self] in try await self.groupLayers($0) }),
            Definition(name: "ungroup_layers", title: "Ungroup",
                       description: "Takes the layers out of groups, where they are, and takes the groups away.",
                       properties: .object([design, ("layers", Self.list("The groups. Leave it out for the selection."))]),
                       run: { [unowned self] in try await self.ungroupLayers($0) }),
            Definition(name: "arrange_layers", title: "Arrange layers",
                       description: "Brings layers to the front or forward, or sends them backward or to the back, among the layers they lie with.",
                       properties: .object([design, layers, ("order", Self.choice(["front", "forward", "backward", "back"], "Where to."))]),
                       required: ["order"], run: { [unowned self] in try await self.arrangeLayers($0) }),
            Definition(name: "align_layers", title: "Align layers",
                       description: "Lines layers up by an edge or their middles. A layer on its own lines up with its artboard.",
                       properties: .object([design, layers, ("edge", Self.choice(["left", "center", "right", "top", "middle", "bottom"], "center is across, middle is up and down."))]),
                       required: ["edge"], run: { [unowned self] in try await self.alignLayers($0) }),
            Definition(name: "distribute_layers", title: "Distribute layers",
                       description: "Spaces three layers or more evenly between the outermost two.",
                       properties: .object([design, layers, ("direction", Self.choice(["horizontal", "vertical"], "Across or down."))]),
                       required: ["direction"], run: { [unowned self] in try await self.distributeLayers($0) }),
            Definition(name: "flip_layers", title: "Flip layers",
                       description: "Mirrors layers where they are: one about its own middle, several about the middle of them all. Words still read forwards.",
                       properties: .object([design, layers, ("direction", Self.choice(["horizontal", "vertical"], "Left to right, or top to bottom."))]),
                       required: ["direction"], run: { [unowned self] in try await self.flipLayers($0) }),
            Definition(name: "select_layers", title: "Select layers",
                       description: "Selects layers on the canvas, for the person to see, or for tools to act on when they are given no layers. An empty list selects nothing.",
                       properties: .object([design, ("layers", Self.list("The layers to select, by id or name; [] for none."))]),
                       required: ["layers"], run: { [unowned self] in try await self.selectLayers($0) }),
            Definition(name: "view", title: "Change the view",
                       description: "Changes what the window shows: zooms, or brings a layer into view. It changes nothing in the design.",
                       properties: .object([
                           design,
                           ("layer", Self.text("A layer to bring whole into view.")),
                           ("zoom", ["description": "1 for actual size, 2 for twice; or \"fit\" for everything, \"selection\" for the selection."]),
                       ]), run: { [unowned self] in try await self.view($0) }),
            Definition(name: "undo", title: "Undo",
                       description: "Undoes the last change to a design, by hand or by you, as Ctrl+Z does.",
                       properties: .object([design, ("steps", Self.integer("How many changes to undo; 1 otherwise."))]),
                       run: { [unowned self] in try await self.undo($0, redo: false) }),
            Definition(name: "redo", title: "Redo",
                       description: "Redoes what was last undone.",
                       properties: .object([design, ("steps", Self.integer("How many; 1 otherwise."))]),
                       run: { [unowned self] in try await self.undo($0, redo: true) }),
            Definition(name: "render", title: "Look at a design",
                       description: "Draws an artboard, a layer, or the whole design as a picture, as it will export, so you can see what you made. Look after making changes, and fix what looks wrong.",
                       properties: .object([
                           design,
                           ("layer", Self.text("An artboard or a layer to draw. The whole design otherwise.")),
                           ("scale", Self.number("Pixels to a point: 2 otherwise, less when that would be bigger than maxSize.")),
                           ("maxSize", Self.integer("The longest side, in pixels; 1568 otherwise.")),
                       ]), readOnly: true, run: { [unowned self] in try await self.render($0) }),
            Definition(name: "export", title: "Export",
                       description: "Exports artboards or layers as files, as the Export panel does: a picture or SVG each, or one PDF with a page each. A carousel goes out a picture a slide. With marked, each goes out as its exports say instead (see update_layers). Files of the same name already there are kept, the new ones numbered, unless replace is true; a / in a name puts the file in a folder.",
                       properties: .object([
                           design,
                           ("layers", Self.list("Artboards or layers to export. The selection otherwise, or every artboard when nothing is selected; with marked, everything marked for export.")),
                           ("format", Self.choice(ExportFormat.offered.filter { $0 != .avif }.map(\.rawValue), "png otherwise.")),
                           ("scale", Self.integer("For pictures (png, jpeg, webp): pixels to a point, 1 to 4; 1 otherwise.")),
                           ("quality", Self.number("For jpeg and webp: how much of the picture is kept, 0 to 1; 0.9 otherwise. 1 makes a webp lossless.")),
                           ("marked", Self.boolean("Export each layer as its exports say, ignoring format and scale.")),
                           ("replace", Self.boolean("Replace files of the same name already in the folder. Ask the user first: false otherwise, which numbers the new files.")),
                           ("folder", Self.text("Where the files go: Downloads otherwise.")),
                       ]), run: { [unowned self] in try await self.export($0) }),
            Definition(name: "list_fonts", title: "List fonts",
                       description: "Lists the font families Bezzle has, or the faces of one, as font.family and font.face take them.",
                       properties: .object([
                           ("family", Self.text("A family whose faces to list.")),
                           ("search", Self.text("Only families whose name has this in it.")),
                       ]), readOnly: true, run: { [unowned self] in try self.listFonts($0) }),

        ]
    }

    /// What a layer can be given, when it is added or changed.
    private static var layerProperties: [(String, JSONValue)] {
        [
            ("name", text("Its name in the layers list.")),
            ("x", number("Its left. An artboard's is on the canvas; any other layer's is measured from the left of the artboard or group it lies in.")),
            ("y", number("Its top, measured as x is. y points down.")),
            ("width", number("For text, the width its words wrap to.")),
            ("height", number("Text is as tall as its words, unless font.sizing is \"fixed\".")),
            ("rotation", number("Degrees clockwise about its middle.")),
            ("opacity", number("0 to 1.")),
            ("hidden", boolean("Hidden layers are neither drawn nor exported.")),
            ("locked", boolean("Locked layers cannot be picked or moved on the canvas.")),
            ("fill", ["description": "A colour (\"#RRGGBB\", or \"#RRGGBBAA\" with transparency) for a solid fill; \"none\"; or an object {color, gradient, image, on}. gradient: {type: \"linear\" or \"radial\", stops: a list of colours, or of {offset 0–1, color}; angle: in degrees as CSS counts it, 180 running downward, the usual; or start and end {x, y}, 0–1 across the layer; radial: start is the middle, radius 0–1}; null takes it away. image: {mode: cover, fit or stretch; offset {x, y}, each -1 to 1; scale, 1 or more} adjusts a picture place_image put in; null takes it away. Text is coloured by its fill: a gradient or a picture paints every letter that has no colour of its own in spans. A list of these is several fills, bottom first, each painted over the one before (such as a picture with a gradient over it); a picture can only be the first. One fill on its own changes the first; \"none\" takes them all away."]),
            ("border", ["description": "\"none\", a colour, a width, or {color, gradient, width, position: inside, center or outside; dash and gap, in points, for a dashed line}. gradient is as fill's, placed across the layer the same way, and paints the border in place of its colour; null takes it away. A border painted with a picture (as one imported or set in the app) gives it back as image; image: null takes it away. A colour on its own, as a string, makes it solid again. A list of these is several borders, bottom first, each drawn over the one before (such as a ring outside and a line inside). One on its own changes the first; \"none\" takes them all away."]),
            ("shadow", ["description": "\"none\"; a preset: \"subtle\", \"soft\", \"lifted\" or \"floating\" under the layer, or \"etched\", \"pressed\", \"sunken\" or \"deep\" inside it; a colour; or {color, x, y, blur, spread, inset}. inset: true puts the shadow inside the layer, as if pressed into the page (not on lines). spread grows the shape the shadow is cast from by that many points all round, or shrinks it below 0 (shapes and lines only; inside a shape it narrows the hollow). A list of these is several shadows, cast together, under the layer and inside it at once if you like (a close one and a soft one under it look most real). One on its own changes the first; \"none\" takes them all away."]),
            ("cornerRadius", ["description": "Rectangles: a radius; four, [top left, top right, bottom right, bottom left]; or \"pill\", for ends fully round."]),
            ("cornerSmoothing", number("Rectangles: how smoothly the corners run into the sides, from 0 (quarter circles) to 1. 0.6 is the squircle of iOS icons.")),
            ("text", text("Text layers: the words. \\n starts a new line. Words set without spans keep the looks of their letters where they are the same words as before.")),
            ("spans", ["type": "array", "description": "Text layers: the words in runs, end to end, where some letters look different from the rest, such as [{\"text\": \"Hello \"}, {\"text\": \"World\", \"face\": \"Bold\", \"color\": \"#E5484D\"}]. Each is {text, and any of family, face, size, color, underline, strikethrough, tracking, list (bullet or number, for its paragraph)}; what a run does not give is as font says. They make the words, in place of text. null makes every letter look alike again. style_text styles words without giving them all.", "items": ["type": "object"]]),
            ("font", ["type": "object", "description": "Text layers. Only what is given changes.", "properties": [
                "family": text("A font family as list_fonts gives it, or \"System\" for SF Pro."),
                "face": text("\"Regular\", \"Bold\", \"Semibold Italic\"…: the family's faces, as list_fonts gives them."),
                "size": number("In points."),
                "align": choice(["left", "center", "right", "justify"], "How the lines line up. justify runs every line but a paragraph's last from side to side."),
                "lineSpacing": number("From one line's baseline to the next, in points; null for the font's own."),
                "tracking": number("Space between letters, in thousandths of the size."),
                "underline": boolean("Underlined."),
                "sizing": choice(["auto", "fixedWidth", "fixed"], "auto: as wide as its words (the usual for a heading or label). fixedWidth: wrapped at its width, as tall as the words (for a paragraph). fixed: a box of set width and height."),
                "case": choice(["upper", "lower", "title", "smallCaps", "none"], "Set in capitals, small letters, capitalised words or small capitals, whatever the text is."),
                "strikethrough": boolean("A line through the letters."),
                "paragraphSpacing": number("Space after each paragraph but the last, in points; 0 or null for none."),
                "vertical": choice(["top", "middle", "bottom"], "With sizing fixed: where the lines lie in the box."),
                "features": ["type": "object", "description": "OpenType features by their four-letter tags: 1 or true on, 0 or false off, null as the font sets it. Such as {\"onum\": 1} old-style figures, {\"tnum\": 1} tabular figures, {\"liga\": 0} no ligatures, {\"ss01\": 1} a stylistic set. null for all as the font sets them."],
                "axes": ["type": "object", "description": "A variable font's axes by their tags, such as {\"wght\": 650, \"wdth\": 90}: weight, width, optical size (opsz), slant (slnt). null for the face's own. SF Pro (System) has wght 1–1000 and wdth 30–150."],
            ]]),
            ("blur", ["description": "\"none\"; a radius, blurring the layer; or {radius, background: true to blur what lies behind it instead, like frosted glass; brightness -1 to 1 and fillOpacity 0 to 1, for a background blur; ramp, for a blur that grows across the layer rather than lying even: the edge it blurs toward, \"bottom\", \"left\", \"top\" or \"right\", or {start, end} as points in the layer's box from 0 to 1 like a gradient's, sharp at start and blurred by the whole radius at end, or \"none\"}."]),
            ("transform3D", ["description": "Holds the layer up off the page in perspective, seen from in front of its middle: {x, y, z}. x: degrees tipped back about its horizontal middle, the top going away for more than 0; y: degrees swung round its vertical middle, the right side going away for more than 0 (as CSS rotateX and rotateY, after its own rotation); z: points nearer the viewer, or further below 0. corners: four points in its parent where its top left, top right, bottom right and bottom left show, pinned there before any turn, as a mockup's screen is laid onto a photo; \"none\" lays them square again. \"none\" or null lays it flat. Not on artboards."]),
            ("blend", choice(["normal"] + BlendMode.allCases.map(\.rawValue), "How its colours mix with what lies under it.")),
            ("x1", number("Lines: where one end is, in the parent.")),
            ("y1", number("Lines: where one end is.")),
            ("x2", number("Lines: where the other end is.")),
            ("y2", number("Lines: where the other end is.")),
            ("path", text("Paths: the outline as SVG path data (M L H V C S Q T A Z, absolute or relative) in the parent's coordinates. The layer's frame becomes the box round it; give width and height too to stretch it.")),
            ("evenOdd", boolean("Paths: whether where the outline overlaps itself is cut out.")),
            ("clips", boolean("Artboards: whether what reaches past the edge is cut off there. True otherwise.")),
            ("preset", text("Artboards: a size by name: \(Preset.all.map(\.name).joined(separator: ", ")).")),
            ("carousel", ["description": .string("Artboards: makes it a carousel of slides side by side, exported a picture a slide: a format, \(Carousel.formats.map { "\"\($0.name)\" (\(Int($0.size.width))×\(Int($0.size.height)))" }.joined(separator: ", ")), or {width, height} of a slide; null makes it one artboard again. Its width is always a whole number of slides.")]),
            ("slides", integer("Carousels: how many slides, 1 to 20.")),
            ("adapts", boolean("Artboards: whether its design is laid out again whenever its size changes (by width, height or preset), as resizing it on the canvas does: read as backdrops, bars, blocks in rows and columns and the gaps between them, then grown or shrunk to suit the new size, its type with it, bars and panels stretched, text rewrapped, pictures cropped round what they show, a picture beside its words on a wide format and above them on a tall one, cards in a row wrapped into a grid. True unless set; false keeps its layers where they are.")),
            ("exports", ["description": .string("Marks it for export: the files it goes out as whenever what is marked is exported (export with marked), each {size: pixels to a point, \"2x\", or pixels wide or tall, \"512w\" or \"64h\"; format: \(ExportFormat.offered.map(\.rawValue).joined(separator: ", ")); suffix: what goes after its name, \"@2x\" at 2x otherwise, a / making a folder}. [\"1x\", \"2x\", \"3x\"] makes the PNGs iOS takes. \"none\" unmarks it.")]),
        ]
    }

    private static func text(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    private static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    private static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    private static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    private static func list(_ description: String) -> JSONValue { ["type": "array", "items": ["type": "string"], "description": .string(description)] }

    private static func choice(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }
}
