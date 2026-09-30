import {
  advanceSimulation,
} from './simulation/model.js';

import {
  addStopA,
  addStopB,
  addVehicle,
  buildCorridorB,
  buildFirstLine,
  buildInterchange,
  buildStationB,
  buildTerminalA,
  buyUpgrade,
  setSimulationSpeed,
} from './simulation/actions.js';

import {
  clearSave,
  loadState,
  saveState,
} from './persistence/storage.js';

import {
  TransportRenderer,
} from './render/transportRenderer.js';

import {
  Hud,
} from './ui/hud.js';

const canvas = document.querySelector('#transport-canvas');

let state = loadState();
let hud;

const toastFailure = (result) => {
  const messages = {
    'insufficient-funds': 'Not enough funds.',
    'line-required': 'Start Line 1 first.',
    'terminal-required': 'Build Northside Terminal first.',
    'interchange-required': 'Build Central Interchange first.',
    'corridor-required': 'Open Line 2 first.',
    'station-b-required': 'Build Harbor Station first.',
    'stop-limit': 'Stop limit reached for this prototype.',
    'fleet-limit': 'Fleet limit reached for this line.',
    'already-built': 'That infrastructure is already open.',
  };

  hud.toast(
    messages[result.reason]
      ?? 'Action unavailable.',
  );
};

const renderer = new TransportRenderer(
  canvas,
  {
    onSelectionChanged: (selection) => {
      hud?.setSelection(selection);
    },
  },
);

hud = new Hud({
  onBuild: (type) => {
    const buildActions = {
      lineA: {
        run: () => buildFirstLine(state),
        selection: 'corridorA',
        success: 'Bus Line 1 is now carrying passengers.',
      },
      terminalA: {
        run: () => buildTerminalA(state),
        selection: 'terminalA',
        success: 'Northside Terminal is open.',
      },
      interchange: {
        run: () => buildInterchange(state),
        selection: 'interchange',
        success: 'Central Interchange is open. Existing Line 1 stayed in place.',
      },
      corridorB: {
        run: () => buildCorridorB(state),
        selection: 'corridorB',
        success: 'Bus Line 2 is now serving Riverside.',
      },
      stationB: {
        run: () => buildStationB(state),
        selection: 'stationB',
        success: 'Harbor Station is open.',
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

  onAddStopA: () => {
    const result = addStopA(state);

    if (result.ok) {
      hud.toast('New stop added to Bus Line 1. Route time increased.');
    } else {
      toastFailure(result);
    }
  },

  onAddStopB: () => {
    const result = addStopB(state);

    if (result.ok) {
      hud.toast('New stop added to Bus Line 2. Route time increased.');
    } else {
      toastFailure(result);
    }
  },

  onAddVehicleA: () => {
    const result = addVehicle(state, 'corridorA');

    if (result.ok) {
      hud.toast('Bus added to Line 1. Headway reduced.');
    } else {
      toastFailure(result);
    }
  },

  onAddVehicleB: () => {
    const result = addVehicle(state, 'corridorB');

    if (result.ok) {
      hud.toast('Bus added to Line 2. Headway reduced.');
    } else {
      toastFailure(result);
    }
  },

  onUpgrade: (type) => {
    const result = buyUpgrade(state, type);

    if (result.ok) {
      hud.toast('Transport capacity upgraded.');
    } else {
      toastFailure(result);
    }
  },

  onSpeed: (speed) => {
    setSimulationSpeed(state, speed);
  },

  onInspectorClose: () => {
    renderer.setSelection(null);
  },

  onReset: () => {
    clearSave();
    location.reload();
  },
});

let last = performance.now();
let saveAccumulator = 0;

function frame(now) {
  const delta = Math.min(
    (now - last) / 1000,
    0.1,
  );

  last = now;

  advanceSimulation(
    state,
    delta,
  );

  renderer.render(
    state,
    delta,
  );

  hud.render(state);

  saveAccumulator += delta;

  if (saveAccumulator >= 2) {
    saveState(state);
    saveAccumulator = 0;
  }

  requestAnimationFrame(frame);
}

window.addEventListener(
  'beforeunload',
  () => saveState(state),
);

hud.render(state);
requestAnimationFrame(frame);
