const Vue = require('vue')
const Vuetify = require('vuetify/dist/vuetify.js')
const Vuex = require('vuex').default || require('vuex')
const { mount, createLocalVue } = require('@vue/test-utils')
const ScanUnitLoad = require('@/components/transferOrder/scanUnitLoad.vue').default
Vue.use(Vuetify)
const localVue = createLocalVue(); localVue.use(Vuex)
const flush = () => new Promise(r => setTimeout(r, 0))
function build(sources) {
  const dispatched = []
  const store = new Vuex.Store({ modules: { transferOrder: { namespaced: true,
    state: { process: '3_unitLoad', order: { transferlane: 'TL19' }, orderPosition: { skuName: 'x', transferOrderPositionPickSourceDtoList: sources } },
    mutations: { setOrderPosition() {}, setOrderPositions() {}, setOrder() {}, setProcess() {} },
    actions: { processScanUnitLoad(_c, p) { dispatched.push(p.inputUnitLoad) } } } } })
  const el = document.createElement('div'); el.setAttribute('data-app', 'true'); document.body.appendChild(el)
  const w = mount(ScanUnitLoad, { store, localVue, vuetify: new Vuetify(), attachTo: el })
  return { w, dispatched }
}
async function scan(w, text) {
  const input = w.find('input#valueScan')
  input.element.focus(); await input.trigger('focus')
  for (const ch of text) { input.element.value += ch; await input.trigger('input'); await flush() }
  await input.trigger('keydown', { keyCode: 13, key: 'Enter' }); await flush(); await flush()
  await input.trigger('keyup', { keyCode: 13, key: 'Enter' }); await flush(); await flush()
  return input
}
const S = [
  { stockUnitId: 1, locationName: '37-XG06', unitLoadLabel: 'UL351514', amountOnPosition: 6 },
  { stockUnitId: 2, locationName: '37-XG06', unitLoadLabel: 'UL340022', amountOnPosition: 102 },
]
it('A: scan of a non-eligible prefix label', async () => {
  const { w, dispatched } = build(S); await scan(w, 'UL35151')
  console.log('A dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages), 'sel', w.vm.selectedLabel)
})
it('B: scan of a LOCATION barcode', async () => {
  const { w, dispatched } = build(S); await scan(w, '37-XG06')
  console.log('B dispatched', JSON.stringify(dispatched), 'errors', JSON.stringify(w.vm.errorMessages), 'sel', w.vm.selectedLabel)
})
it('C: exact scan then a second scan while selected', async () => {
  const { w, dispatched } = build(S); const input = await scan(w, 'UL351514')
  console.log('C1 dispatched', JSON.stringify(dispatched), 'sel', w.vm.selectedLabel, 'search', JSON.stringify(w.vm.searchText), 'inputval', JSON.stringify(input.element.value))
  await scan(w, 'UL340022')
  console.log('C2 dispatched', JSON.stringify(dispatched), 'sel', w.vm.selectedLabel, 'search', JSON.stringify(w.vm.searchText), 'errors', JSON.stringify(w.vm.errorMessages))
})
it('D: invalid typed then tap Submit (click-outside blur)', async () => {
  const { w, dispatched } = build(S)
  const input = w.find('input#valueScan'); input.element.focus(); await input.trigger('focus')
  input.element.value = 'UL999'; await input.trigger('input'); await flush()
  const btn = w.findAll('button').filter(b => b.text() === 'Submit').at(0)
  btn.element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
  btn.element.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }))
  btn.element.dispatchEvent(new MouseEvent('click', { bubbles: true }))
  console.log('D right after click errors', JSON.stringify(w.vm.errorMessages), 'search', JSON.stringify(w.vm.searchText))
  await flush(); await flush(); await flush()
  console.log('D after timers errors', JSON.stringify(w.vm.errorMessages), 'search', JSON.stringify(w.vm.searchText), 'dispatched', JSON.stringify(dispatched))
})
