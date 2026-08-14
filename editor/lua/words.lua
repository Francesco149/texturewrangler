-- words.lua — dictionary words for random project names ("furry-cobblestone").
local words = {}

local adj = {
  "furry", "cobbled", "warped", "gilded", "mossy", "frozen", "smoky", "glassy",
  "rusted", "woven", "chipped", "sunlit", "dusky", "briny", "crumbling",
  "polished", "painted", "faded", "burnished", "icy", "dusty", "marbled",
  "rusted", "speckled", "velvet", "weathered", "glowing", "violet", "amber",
  "steel", "silken", "stony", "liquid", "static", "pixelated", "crushed",
  "folded", "scorched", "damp", "hollow", "fractal", "sine", "plasma", "vapor",
  "candy", "neon", "ghostly", "cracked", "hammered", "sanded", "waxed",
}

local noun = {
  "cobblestone", "brickwork", "tileset", "shingle", "pavement", "mosaic",
  "tapestry", "wainscot", "granite", "basalt", "slate", "plaster", "gesso",
  "linen", "burlap", "leather", "patina", "verdigris", "stucco", "terracotta",
  "porcelain", "enamel", "lacquer", "bitumen", "soot", "gravel", "loam",
  "peat", "rubble", "sherd", "shard", "runes", "glyphs", "sigils", "weave",
  "grain", "filigree", "scrollwork", "checker", "herringbone", "quilt",
  "fur", "moss", "lichen", "bark", "fern", "reed", "thistle", "honeycomb",
}

function words.random_name()
  math.randomseed(os.time() * 1000 + (os.clock() * 1000) % 1000)
  return adj[math.random(#adj)] .. "-" .. noun[math.random(#noun)]
end

return words
