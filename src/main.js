import { advanceSimulation } from './simulation/model.js';
import { addClient, buildEthernet, buildSwitch, buyUpgrade, setSimulationSpeed } from './simulation/actions.js';
import { clearSave, loadState, saveState } from './persistence/storage.js';
import { NetworkRenderer } from './render/networkRenderer.js';
import { Hud } from './ui/hud.js';

const canvas = document.querySelector('#network-canvas');
let state = loadState();

const renderer = new NetworkRenderer(canvas);
const hud = new Hud({
  onConnect: () => {
    const result = buildEthernet(state);
    if (result.ok) hud.toast('Ethernet link online. Traffic started.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },
  onBuildSwitch: () => {
    const result = buildSwitch(state);
    if (result.ok) hud.toast('Switch online. Multiple clients unlocked.');
    else if (result.reason === 'link-required') hud.toast('Build the Ethernet link first.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },
  onAddClient: () => {
    const result = addClient(state);
    if (result.ok) hud.toast('New client connected. Demand increased.');
    else if (result.reason === 'switch-required') hud.toast('Install a switch first.');
    else if (result.reason === 'client-limit') hud.toast('Client limit reached for Phase 2.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },
  onUpgrade: (type) => {
    const result = buyUpgrade(state, type);
    if (result.ok) hud.toast(`${type.toUpperCase()} upgraded.`);
    else if (result.reason === 'link-required') hud.toast('Build the Ethernet link first.');
    else if (result.reason === 'switch-required') hud.toast('Install a switch first.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },
  onSpeed: (speed) => setSimulationSpeed(state, speed),
  onReset: () => {
    clearSave();
    location.reload();
  },
});

let last = performance.now();
let saveAccumulator = 0;

function frame(now) {
  const delta = Math.min((now - last) / 1000, 0.1);
  last = now;

  advanceSimulation(state, delta);
  renderer.render(state, delta);
  hud.render(state);

  saveAccumulator += delta;
  if (saveAccumulator >= 2) {
    saveState(state);
    saveAccumulator = 0;
  }

  requestAnimationFrame(frame);
}

window.addEventListener('beforeunload', () => saveState(state));
hud.render(state);
requestAnimationFrame(frame);
