.pragma library

// Surface presets use the same special colors as BoardHydra's web palette.
var presets = [
  { key: "classic", label: "Classic", tone: "#349aa5", base: "#221d33", accents: ["#2785c2", "#349aa5", "#41aa90", "#4db381"] },
  { key: "holo", label: "Holo", tone: "#c86eff", base: "#261d36", accents: ["#c86eff", "#5ee0ff", "#ff6fb5", "#4de1c1"] },
  { key: "aurora", label: "Aurora", tone: "#4de1c1", base: "#162e30", accents: ["#4de1c1", "#5ee0ff", "#b265ff", "#4fd27a"] },
  { key: "gold", label: "Gold", tone: "#e7b84b", base: "#30271c", accents: ["#e7b84b", "#f2c35b", "#ffb347", "#ffd166"] },
  { key: "obsidian", label: "Obsidian", tone: "#8a8399", base: "#17141f", accents: ["#8a8399", "#9a91b3", "#6c6487", "#b1a7c5"] }
]

function preset(key) {
  for (var i = 0; i < presets.length; i++) if (presets[i].key === key) return presets[i]
  return presets[0]
}

function hex(value) {
  return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value) ? value.toLowerCase() : ""
}

function ink(value) {
  var color = hex(value) || "#221d33"
  var rgb = [1, 3, 5].map(function(i) {
    var c = parseInt(color.slice(i, i + 2), 16) / 255
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
  })
  return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722 > 0.179 ? "#15121f" : "#ece6f7"
}

function validate(value) {
  var v = value && typeof value === "object" ? value : {}
  return {
    preset: preset(v.preset).key,
    tint: hex(v.tint),
    accents: [0, 1, 2, 3].map(function(i) { return hex(Array.isArray(v.accents) ? v.accents[i] : "") }),
    motion: v.motion !== false
  }
}

function accents(value) {
  return preset(value.preset).accents.map(function(c, i) { return value.accents[i] || c })
}
