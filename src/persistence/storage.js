import { GAME_VERSION, createInitialState } from '../simulation/model.js';

const SAVE_KEY = 'i-like-networks.phase1.save';

export function loadState() {
  try {
    const raw = localStorage.getItem(SAVE_KEY);
    if (!raw) return createInitialState();
    const parsed = JSON.parse(raw);
    if (parsed.version !== GAME_VERSION) return createInitialState();
    return parsed;
  } catch {
    return createInitialState();
  }
}

export function saveState(state) {
  localStorage.setItem(SAVE_KEY, JSON.stringify(state));
}

export function clearSave() {
  localStorage.removeItem(SAVE_KEY);
}
