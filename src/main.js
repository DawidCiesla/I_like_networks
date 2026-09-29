import { advanceSimulation } from './simulation/model.js';
import {
  addBranchClient,
  addClient,
  buildBranchNetwork,
  buildEthernet,
  buildRouter,
  buildSecondaryServer,
  buildSwitch,
  buyUpgrade,
  setSimulationSpeed,
} from './simulation/actions.js';
import { clearSave, loadState, saveState } from './persistence/storage.js';
import { NetworkRenderer } from './render/networkRenderer.js';
import { Hud } from './ui/hud.js';

const canvas = document.querySelector('#network-canvas');
let state = loadState();

const renderer = new NetworkRenderer(canvas);
const hud = new Hud({
  onConnect: () => {
    const result = buildEthernet(state);
    if (result.ok) hud.toast('Ethernet link online.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onBuildSwitch: () => {
    const result = buildSwitch(state);
    if (result.ok) hud.toast('LAN A switch online.');
    else if (result.reason === 'link-required') hud.toast('Build Ethernet first.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onBuildRouter: () => {
    const result = buildRouter(state);
    if (result.ok) hud.toast('Router online. Routing table initialized.');
    else if (result.reason === 'switch-required') hud.toast('Install the switch first.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onAddClient: () => {
    const result = addClient(state);
    if (result.ok) hud.toast('LAN A client connected.');
    else if (result.reason === 'client-limit') hud.toast('LAN A client limit reached.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onBuildBranch: () => {
    const result = buildBranchNetwork(state);
    if (result.ok) hud.toast('LAN B online. New route installed.');
    else if (result.reason === 'router-required') hud.toast('Install the router first.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onAddBranchClient: () => {
    const result = addBranchClient(state);
    if (result.ok) hud.toast('LAN B client connected.');
    else if (result.reason === 'branch-required') hud.toast('Build LAN B first.');
    else if (result.reason === 'client-limit') hud.toast('LAN B client limit reached.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onBuildSecondaryServer: () => {
    const result = buildSecondaryServer(state);
    if (result.ok) hud.toast('Server B online. New destination route active.');
    else if (result.reason === 'router-required') hud.toast('Install the router first.');
    else if (result.reason === 'insufficient-funds') hud.toast('Not enough funds.');
  },

  onUpgrade: (type) => {
    const result = buyUpgrade(state, type);
    if (result.ok) hud.toast(`${type.toUpperCase()} upgraded.`);
    else if (result.reason === 'router-required') hud.toast('Install the router first.');
    else if (result.reason === 'branch-required') hud.toast('Build LAN B first.');
    else if (result.reason === 'secondary-server-required') hud.toast('Build Server B first.');
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
