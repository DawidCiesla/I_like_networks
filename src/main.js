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
let hud;

const toastFailure = (result) => {
  const messages = {
    'insufficient-funds': 'Not enough funds.',
    'link-required': 'Build Ethernet first.',
    'switch-required': 'Install the switch first.',
    'router-required': 'Install the router first.',
    'branch-required': 'Build LAN B first.',
    'secondary-server-required': 'Build Server B first.',
    'client-limit': 'Client limit reached.',
    'already-built': 'That element is already online.',
  };

  hud.toast(messages[result.reason] ?? 'Action unavailable.');
};

const renderer = new NetworkRenderer(canvas, {
  onSelectionChanged: (selection) => hud?.setSelection(selection),
});

hud = new Hud({
  onBuild: (type) => {
    const buildActions = {
      ethernet: {
        run: () => buildEthernet(state),
        selection: 'lanA',
        success: 'Ethernet online. Existing route established.',
      },
      switch: {
        run: () => buildSwitch(state),
        selection: 'switch',
        success: 'Switch installed on the existing LAN.',
      },
      router: {
        run: () => buildRouter(state),
        selection: 'router',
        success: 'Router inserted into the existing trunk.',
      },
      branch: {
        run: () => buildBranchNetwork(state),
        selection: 'lanB',
        success: 'LAN B added to the existing network.',
      },
      server2: {
        run: () => buildSecondaryServer(state),
        selection: 'serverB',
        success: 'Server B and its new route are online.',
      },
    };

    const action = buildActions[type];
    if (!action) return;

    const result = action.run();

    if (result.ok) {
      renderer.setSelection(action.selection);
      hud.setSelection(action.selection);
      hud.toast(action.success);
    } else {
      toastFailure(result);
    }
  },

  onAddClient: () => {
    const result = addClient(state);
    if (result.ok) hud.toast('LAN A client connected.');
    else toastFailure(result);
  },

  onAddBranchClient: () => {
    const result = addBranchClient(state);
    if (result.ok) hud.toast('LAN B client connected.');
    else toastFailure(result);
  },

  onUpgrade: (type) => {
    const result = buyUpgrade(state, type);
    if (result.ok) hud.toast(`${type.toUpperCase()} upgraded.`);
    else toastFailure(result);
  },

  onSpeed: (speed) => setSimulationSpeed(state, speed),

  onInspectorClose: () => renderer.setSelection(null),

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
