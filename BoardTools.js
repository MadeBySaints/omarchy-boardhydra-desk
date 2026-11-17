.pragma library

function bounded(value, max) { return typeof value === "string" ? value.slice(0, max) : "" }
function ids(value) {
  if (!Array.isArray(value)) return []
  return value.filter(function(x, i) {
    return typeof x === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(x) && value.indexOf(x) === i
  }).slice(0, 200)
}

function matches(card, detail, filters, now) {
  var f = filters || {}, d = detail || {}
  var query = bounded(f.query, 200).trim().toLowerCase()
  if (query && (String(card.text || "") + " " + String(d.desc || "")).toLowerCase().indexOf(query) < 0) return false
  if (f.status === "incomplete" && card.dueComplete) return false
  if (f.status === "complete" && !card.dueComplete) return false
  var due = card.due ? new Date(card.due).getTime() : NaN
  if (f.due === "overdue" && (card.dueComplete || !(due < now))) return false
  if (f.due === "week" && (card.dueComplete || !(due >= now && due <= now + 7 * 86400000))) return false
  if (f.due === "none" && card.due) return false
  if (f.label && (d.labelIds || []).indexOf(f.label) < 0) return false
  if (f.member && (d.memberIds || []).indexOf(f.member) < 0) return false
  return true
}

// Keep only reusable checklist content, with a single bounded item budget.
function checklists(value, freshId, keepDone) {
  var budget = 500
  function items(list, depth) {
    if (!Array.isArray(list) || depth > 2) return []
    var out = []
    for (var i = 0; i < list.length && budget > 0; i++) {
      var item = list[i]
      if (!item || typeof item !== "object") continue
      var name = bounded(item.name, 500).trim()
      if (!name) continue
      budget--
      var next = { name: name, state: keepDone && item.state === "complete" ? "complete" : "incomplete", pos: (out.length + 1) * 65536 }
      if (freshId) next.id = freshId()
      else if (ids([item.id]).length) next.id = item.id
      var children = items(item.children, depth + 1)
      if (children.length) next.children = children
      out.push(next)
    }
    return out
  }
  return (Array.isArray(value) ? value : []).slice(0, 50).filter(function(x) { return x && typeof x === "object" }).map(function(x, i) {
    var next = { name: bounded(x.name, 100) || "Checklist", pos: (i + 1) * 65536, checkItems: items(x.checkItems, 0) }
    if (freshId) next.id = freshId()
    else if (ids([x.id]).length) next.id = x.id
    return next
  })
}

function templates(value) {
  var seen = []
  return (Array.isArray(value) ? value : []).slice(0, 50).filter(function(x) {
    if (!x || typeof x !== "object" || ids([x.id]).length !== 1 || seen.indexOf(x.id) >= 0 || !bounded(x.name, 80).trim()) return false
    seen.push(x.id)
    return true
  }).map(function(x) {
    return { id: x.id, name: bounded(x.name, 80).trim(), boardId: bounded(x.boardId, 64), title: bounded(x.title, 500),
      desc: bounded(x.desc, 20000), labelIds: ids(x.labelIds), memberIds: ids(x.memberIds), checklists: checklists(x.checklists) }
  })
}

function templatePatch(template, labels, members, freshId) {
  return { desc: template.desc, dueComplete: false,
    idLabels: template.labelIds.filter(function(id) { return labels.indexOf(id) >= 0 }),
    idMembers: template.memberIds.filter(function(id) { return members.indexOf(id) >= 0 }),
    checklists: checklists(template.checklists, freshId) }
}

function addId(existing, id) { return ids((existing || []).concat([id])) }
