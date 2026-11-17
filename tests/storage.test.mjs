import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import vm from 'node:vm'

const context = vm.createContext({})
vm.runInContext(readFileSync(new URL('../Storage.js', import.meta.url), 'utf8').replace('.pragma library', ''), context)
const qml = readFileSync(new URL('../BoardDesk.qml', import.meta.url), 'utf8')
const migration = [...qml.slice(qml.indexOf('Storage.prepare +'), qml.indexOf('"sh", root.dataDir')).matchAll(/'([^'\n]*)'/g)].map(m => m[1]).join('')
const initialize = context.prepare + migration

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'boardhydra-storage-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const home = join(root, 'home')
  const data = join(home, '.local/share/boardhydra-desk')
  const cache = join(root, 'cache/boardhydra-desk')
  const config = join(home, '.config/boardhydra-desk')
  const old = join(home, '.local/share/boardhydra-desk.json')
  mkdirSync(data, { recursive: true })
  mkdirSync(config, { recursive: true })
  const run = (env = {}) => spawnSync('sh', ['-c', initialize, 'sh', data, cache, old, config, '1'], { encoding: 'utf8', env: { ...process.env, ...env } })
  return { root, home, data, cache, config, old, run }
}

const mode = path => statSync(path).mode & 0o777

test('initialization migrates cards and enforces private file and directory modes', t => {
  const f = fixture(t)
  writeFileSync(f.old, '{"secret":"legacy"}', { mode: 0o644 })
  writeFileSync(join(f.config, 'state.json'), '{}', { mode: 0o666 })
  const result = f.run(); assert.equal(result.status, 0, result.stderr)
  for (const dir of [f.data, f.cache, f.config]) assert.equal(mode(dir), 0o700)
  for (const file of [join(f.data, 'board.json'), join(f.config, 'state.json'), join(f.data, '.shared-board-v1')]) assert.equal(mode(file), 0o600)
  assert.equal(readFileSync(join(f.data, 'board.json'), 'utf8'), '{"secret":"legacy"}')
  assert.equal(f.run().status, 0)
})

for (const bits of [0o777, 0o775, 0o773]) {
  test(`rejects searchable shared ancestor ${bits.toString(8)} before migration`, t => {
    const f = fixture(t)
    chmodSync(join(f.home, '.local/share'), bits)
    writeFileSync(f.old, 'confidential')
    assert.notEqual(f.run().status, 0)
    assert.equal(existsSync(join(f.data, 'workspace-1.json')), false)
    assert.equal(readFileSync(f.old, 'utf8'), 'confidential')
  })
}

test('rejects writable config and cache ancestry as well as data ancestry', t => {
  for (const which of ['config', 'cache']) {
    const f = fixture(t)
    const dir = which === 'config' ? join(f.home, '.config') : join(f.root, 'cache')
    mkdirSync(dir, { recursive: true })
    chmodSync(dir, 0o777)
    assert.notEqual(f.run().status, 0)
  }
})

test('rejects symlink ancestors even when the resolved destination is private', t => {
  const f = fixture(t)
  rmSync(join(f.home, '.local'), { recursive: true })
  mkdirSync(join(f.root, 'elsewhere'))
  symlinkSync(join(f.root, 'elsewhere'), join(f.home, '.local'))
  assert.notEqual(f.run().status, 0)
  assert.equal(existsSync(join(f.root, 'elsewhere/share')), false)
})

test('rejects symlink and hardlink JSON without changing their targets', t => {
  for (const kind of ['symlink', 'hardlink']) {
    const f = fixture(t)
    const target = join(f.root, 'target')
    writeFileSync(target, 'untouched', { mode: 0o644 })
    const dest = join(f.data, 'workspace-1.json')
    if (kind === 'symlink') symlinkSync(target, dest)
    else linkSync(target, dest)
    assert.notEqual(f.run().status, 0)
    assert.equal(mode(target), 0o644)
    assert.equal(readFileSync(target, 'utf8'), 'untouched')
  }
})

test('chmod failure aborts initialization', t => {
  const f = fixture(t)
  const bin = join(f.root, 'bin')
  mkdirSync(bin)
  writeFileSync(join(bin, 'chmod'), '#!/bin/sh\nexit 1\n', { mode: 0o755 })
  assert.notEqual(f.run({ PATH: bin + ':' + process.env.PATH }).status, 0)
  assert.equal(existsSync(join(f.data, 'workspace-1.json')), false)
})


test('shared-board migration backs up existing data and runs only once', t => {
  const f = fixture(t)
  writeFileSync(join(f.data, 'board.json'), '{"cards":"previous shared"}')
  writeFileSync(join(f.data, 'workspace-1.json'), '{"cards":"workspace"}')
  writeFileSync(join(f.config, 'state.json'), '{"boardId":"previous"}')
  writeFileSync(join(f.config, 'workspace-1.json'), '{"boardId":"workspace"}')
  const result = f.run(); assert.equal(result.status, 0, result.stderr)
  assert.equal(readFileSync(join(f.data, 'board-before-shared.json'), 'utf8'), '{"cards":"previous shared"}')
  assert.equal(readFileSync(join(f.config, 'state-before-shared.json'), 'utf8'), '{"boardId":"previous"}')
  assert.equal(readFileSync(join(f.data, 'board.json'), 'utf8'), '{"cards":"workspace"}')
  writeFileSync(join(f.data, 'board.json'), '{"cards":"new shared edits"}')
  assert.equal(f.run().status, 0)
  assert.equal(readFileSync(join(f.data, 'board.json'), 'utf8'), '{"cards":"new shared edits"}')
})

test('symlinked migration marker cannot bypass trusted storage checks', t => {
  const f = fixture(t)
  const target = join(f.root, 'marker-target')
  writeFileSync(target, 'untouched', { mode: 0o644 })
  symlinkSync(target, join(f.data, '.shared-board-v1'))
  assert.notEqual(f.run().status, 0)
  assert.equal(mode(target), 0o644)
})
