import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import vm from 'node:vm'

const tools = vm.createContext({})
vm.runInContext(readFileSync(new URL('../BoardTools.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*/, ''), tools)
const plain = value => JSON.parse(JSON.stringify(value))
const now = Date.parse('2026-11-14T12:00:00Z')
const card = { text: 'Review proposal', due: '2026-11-13T12:00:00Z', dueComplete: false }
const detail = { desc: 'Needle in the description', labelIds: ['urgent'], memberIds: ['sam'] }

test('search combines with completion, due date, label and assignment filters', () => {
  const filters = { query: ' NEEDLE ', status: 'incomplete', due: 'overdue', label: 'urgent', member: 'sam' }
  assert.equal(tools.matches(card, detail, filters, now), true)
  for (const patch of [{ query: 'absent' }, { status: 'complete' }, { due: 'week' }, { due: 'none' }, { label: 'other' }, { member: 'other' }]) {
    assert.equal(tools.matches(card, detail, { ...filters, ...patch }, now), false)
  }
  assert.equal(tools.matches({ ...card, dueComplete: true }, detail, filters, now), false)
  assert.equal(tools.matches({ text: 'No date' }, null, { due: 'none' }, now), true)
  assert.equal(tools.matches({ text: 'Bad date', due: 'bad' }, null, { due: 'overdue' }, now), false)
})

test('date filters include the next seven days and exclude completed cards', () => {
  for (const days of [0, 1, 7]) {
    const c = { ...card, due: new Date(now + days * 86400000).toISOString() }
    assert.equal(tools.matches(c, detail, { due: 'week' }, now), true)
    assert.equal(tools.matches({ ...c, dueComplete: true }, detail, { due: 'week' }, now), false)
  }
})

const source = { id: 'template', name: '<img src="https://example.invalid">', title: 'Review', desc: 'Context',
  labelIds: ['urgent', 'foreign'], memberIds: ['sam', 'foreign'],
  checklists: [{ id: 'old-list', name: 'Steps', checkItems: [{ id: 'old-item', name: 'Parent', state: 'complete', children: [{ id: 'old-child', name: 'Child', state: 'complete' }] }] }] }

test('templates bound input and create independent incomplete checklists', () => {
  const [template] = tools.templates([source, null, { id: 'bad id', name: 'Bad' }, source])
  assert.equal(tools.templates([source, null, { id: 'bad id', name: 'Bad' }, source]).length, 1)
  let sequence = 0
  const patch = plain(tools.templatePatch(template, ['urgent'], ['sam'], () => `fresh-${sequence++}`))
  assert.deepEqual(patch.idLabels, ['urgent'])
  assert.deepEqual(patch.idMembers, ['sam'])
  assert.equal(patch.dueComplete, false)
  assert.equal(patch.checklists[0].checkItems[0].state, 'incomplete')
  assert.equal(patch.checklists[0].checkItems[0].children[0].state, 'incomplete')
  const ids = [patch.checklists[0].id, patch.checklists[0].checkItems[0].id, patch.checklists[0].checkItems[0].children[0].id]
  assert.equal(new Set(ids).size, 3)
  assert.ok(ids.every(id => id.startsWith('fresh-')))
  assert.equal(source.checklists[0].checkItems[0].state, 'complete')
  assert.equal(template.name, source.name)
})

test('local persistence retains checklist progress while templates reset it', () => {
  assert.equal(tools.checklists(source.checklists, null, true)[0].checkItems[0].state, 'complete')
  assert.equal(tools.checklists(source.checklists)[0].checkItems[0].state, 'incomplete')
  assert.deepEqual(plain(tools.addId(['existing', 'sam'], 'sam')), ['existing', 'sam'])
  assert.deepEqual(plain(tools.addId(['existing'], 'sam')), ['existing', 'sam'])
})
