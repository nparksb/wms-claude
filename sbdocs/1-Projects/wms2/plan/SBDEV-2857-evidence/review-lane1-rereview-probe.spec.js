const Vue = require('vue')
const Vuetify = require('vuetify/dist/vuetify.js')
const Vuex = require('vuex').default || require('vuex')
const { mount, createLocalVue } = require('@vue/test-utils')
const ScanUnitLoad = require('@/components/transferOrder/scanUnitLoad.vue').default
Vue.use(Vuetify)
const localVue = createLocalVue(); localVue.use(Vuex)
const flush = () => new Promise(r => setTimeout(r, 0))
let wrapper
afterEach(() => { if (wrapper) wrapper.destroy(); document.body.innerHTML = '' })
function build(sources) {
  const dispatched = []
  const store = new Vuex.Store({ modules: { transferOrder: { namespaced: true,
    state: { process: '3_unitLoad', order: { transferlane: 'TL19' }, orderPosition: { skuName: 'x', transferOrderPositionPickSourceDtoList: sources } },
    mutations: { setOrderPosition() {}, setOrderPositions() {}, setOrder() {}, setProcess() {} },
    actions: { processScanUnitLoad(_c, p) { dispatched.push(p.inputUnitLoad); return true } } } } })
  const el = document.createElement('div'); el.setAttribute('data-app', 'true'); document.body.appendChild(el)
  wrapper = mount(ScanUnitLoad, { store, localVue, vuetify: new Vuetify(), attachTo: el })
  return { w: wrapper, dispatched }
}
// replace=true models a device where the highlighted text is replaced by the first typed char
async function type(w, text, replace) {
  const input = w.find('input#valueScan')
  input.element.focus(); await input.trigger('focus'); await flush()
  if (replace) input.element.value = ''
  for (const ch of text) { input.element.value += ch; await input.trigger('input'); await flush() }
  return input
}
async function enter(input) {
  await input.trigger('keydown', { keyCode: 13, key: 'Enter' }); await flush(); await flush()
  await input.trigger('keyup', { keyCode: 13, key: 'Enter' }); await flush(); await flush()
}
const S = [
  { stockUnitId: 1, locationName: '37-XG06', unitLoadLabel: 'UL351514', amountOnPosition: 6 },
  { stockUnitId: 2, locationName: '37-XG06', unitLoadLabel: 'UL340022', amountOnPosition: 102 },
]
const P = [
  { stockUnitId: 1, locationName: 'A', unitLoadLabel: 'UL3515', amountOnPosition: 6 },
  { stockUnitId: 2, locationName: 'B', unitLoadLabel: 'UL351514', amountOnPosition: 9 },
]
it('E: select UL351514 by scan, then REPLACING scan of partial UL3515 + Enter', async () => {
  const { w, dispatched } = build(S)
  await enter(await type(w, 'UL351514'))
  const input = await type(w, 'UL3515', true)
  console.log('E before enter: sel', w.vm.selectedLabel, 'search', JSON.stringify(w.vm.searchText), 'listIndex', w.vm.$refs.unitLoadField.$refs.menu.listIndex)
  await enter(input)
  console.log('E dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('F: prefix labels — select UL3515, then REPLACING scan of UL351514', async () => {
  const { w, dispatched } = build(P)
  await enter(await type(w, 'UL3515'))
  console.log('F1 dispatched', JSON.stringify(dispatched), 'sel', w.vm.selectedLabel)
  await enter(await type(w, 'UL351514', true))
  console.log('F2 dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('F3: prefix labels, fresh screen, scan UL3515 exact', async () => {
  const { w, dispatched } = build(P)
  await enter(await type(w, 'UL3515'))
  console.log('F3 dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('G: Tab suffix after a scan', async () => {
  const { w, dispatched } = build(S)
  const input = await type(w, 'UL340022')
  await input.trigger('keydown', { keyCode: 9, key: 'Tab' }); await flush(); await flush(); await flush()
  console.log('G dispatched', JSON.stringify(dispatched), 'sel', w.vm.selectedLabel, 'search', JSON.stringify(w.vm.searchText))
})
it('H: arrow-down highlight then Enter on a partial scan', async () => {
  const { w, dispatched } = build(S)
  const input = await type(w, 'UL3')
  await input.trigger('keydown', { keyCode: 40, key: 'ArrowDown' }); await flush(); await flush()
  await enter(input)
  console.log('H dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('F4: prefix labels — TAP UL3515, then REPLACING scan of UL351514', async () => {
  const { w, dispatched } = build(P)
  w.vm.selectedLabel = 'UL3515'; await flush(); await flush()
  await enter(await type(w, 'UL351514', true))
  console.log('F4 dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('F5: prefix labels — TAP UL3515, then APPENDED scan of UL351514', async () => {
  const { w, dispatched } = build(P)
  w.vm.selectedLabel = 'UL3515'; await flush(); await flush()
  await enter(await type(w, 'UL351514', false))
  console.log('F5 dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('E2: TAP UL351514, then REPLACING partial scan UL3515', async () => {
  const { w, dispatched } = build(S)
  w.vm.selectedLabel = 'UL351514'; await flush(); await flush()
  const input = await type(w, 'UL3515', true)
  console.log('E2 before enter listIndex', w.vm.$refs.unitLoadField.$refs.menu.listIndex, 'sel', w.vm.selectedLabel)
  await enter(input)
  console.log('E2 dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('E3: real tile click on UL351514, then REPLACING partial scan UL3515', async () => {
  const { w, dispatched } = build(S)
  const input = await type(w, 'UL')
  const tiles = document.querySelectorAll('.v-list-item')
  console.log('E3 tiles', tiles.length)
  if (tiles.length) { tiles[0].click(); await flush(); await flush() }
  console.log('E3 after click sel', w.vm.selectedLabel, 'value', JSON.stringify(input.element.value), 'selStart', input.element.selectionStart, 'selEnd', input.element.selectionEnd)
  const i2 = await type(w, 'UL3515', true)
  console.log('E3 listIndex', w.vm.$refs.unitLoadField.$refs.menu.listIndex)
  await enter(i2)
  console.log('E3 dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages))
})
