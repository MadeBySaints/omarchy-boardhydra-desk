import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import vm from 'node:vm'

const context = vm.createContext({})
vm.runInContext(readFileSync(new URL('../Appearance.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*/, ''), context)
const plain = (value) => JSON.parse(JSON.stringify(value))

test('old and malformed settings restore the Classic defaults', () => {
  const defaults = plain(context.validate(null))
  for (const value of [undefined, {}, [], 'holo', { preset: '__proto__', tint: '#fff', accents: 'red', motion: 'false' }]) {
    assert.deepEqual(plain(context.validate(value)), defaults)
  }
})

test('custom colors are bounded hex values with preset fallbacks', () => {
  const settings = context.validate({ preset: 'holo', tint: '#ABCDEF', accents: ['#123456', 'red', '#00ff00', '#ff00ff', '#999999'], motion: false })
  assert.equal(settings.tint, '#abcdef')
  assert.equal(settings.motion, false)
  assert.deepEqual(plain(context.accents(settings)), ['#123456', '#5ee0ff', '#00ff00', '#ff00ff'])
  assert.equal(settings.accents.length, 4)
  assert.equal(context.validate({ tint: '<img src="https://example.invalid">' }).tint, '')
})

test('each preset survives a settings round trip and reset clears overrides', () => {
  for (const preset of context.presets) {
    const saved = JSON.stringify(context.validate({ preset: preset.key }))
    const restored = context.validate(JSON.parse(saved))
    assert.equal(restored.preset, preset.key)
    assert.deepEqual(plain(context.accents(restored)), plain(preset.accents))
    assert.equal(restored.tint, '')
  }
})


test('card text stays readable on light and dark custom colors', () => {
  assert.equal(context.ink('#ffffff'), '#15121f')
  assert.equal(context.ink('#000000'), '#ece6f7')
  for (const preset of context.presets) assert.equal(context.ink(preset.base), '#ece6f7')
})
