import { ECONOMY, getIncomePerSecond, getThroughputMbps, getUpgradeCost, getUtilization } from '../simulation/model.js';

const compact = (value) => {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 0 : 1)}m`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value >= 10_000 ? 0 : 1)}k`;
  return value.toFixed(value < 100 ? 1 : 0);
};

const money = (value) => `$${compact(value)}`;

export class Hud {
  constructor({ onConnect, onUpgrade, onSpeed, onReset }) {
    this.el = {
      money: document.querySelector('#money-value'),
      throughput: document.querySelector('#throughput-value'),
      income: document.querySelector('#income-value'),
      objective: document.querySelector('#objective-text'),
      connect: document.querySelector('#connect-button'),
      connectSubtitle: document.querySelector('#connect-subtitle'),
      connectCost: document.querySelector('#connect-cost'),
      demand: document.querySelector('#demand-value'),
      capacity: document.querySelector('#capacity-value'),
      server: document.querySelector('#server-value'),
      utilization: document.querySelector('#utilization-value'),
      toast: document.querySelector('#toast'),
      reset: document.querySelector('#reset-button'),
    };

    this.el.connect.addEventListener('click', onConnect);
    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      button.addEventListener('click', () => onUpgrade(button.dataset.upgrade));
    });
    document.querySelectorAll('[data-speed]').forEach((button) => {
      button.addEventListener('click', () => onSpeed(Number(button.dataset.speed)));
    });
    this.el.reset.addEventListener('click', onReset);
  }

  render(state) {
    const throughput = getThroughputMbps(state);
    const income = getIncomePerSecond(state);

    this.el.money.textContent = compact(state.money);
    this.el.throughput.textContent = `${throughput.toFixed(0)} Mb/s`;
    this.el.income.textContent = `+${compact(income)}/s`;
    this.el.demand.textContent = `${state.client.trafficMbps} Mb/s`;
    this.el.capacity.textContent = state.linkBuilt ? `${state.link.capacityMbps} Mb/s` : '—';
    this.el.server.textContent = `${state.server.capacityMbps} Mb/s`;
    this.el.utilization.textContent = `${Math.round(getUtilization(state) * 100)}%`;

    this.el.connect.disabled = state.linkBuilt || state.money < ECONOMY.ethernetBuildCost;
    this.el.connectSubtitle.textContent = state.linkBuilt ? 'Traffic online' : 'Client ↔ Server';
    this.el.connectCost.textContent = state.linkBuilt ? 'ONLINE' : money(ECONOMY.ethernetBuildCost);

    if (!state.linkBuilt) {
      this.el.objective.textContent = 'Connect the client to the server.';
    } else if (getUtilization(state) >= 0.9) {
      this.el.objective.textContent = 'The link is getting busy. Upgrade capacity.';
    } else {
      this.el.objective.textContent = 'Looking a bit more interesting.';
    }

    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      const type = button.dataset.upgrade;
      const cost = getUpgradeCost(state, type);
      const costElement = button.querySelector('.row-cost strong');
      if (costElement) costElement.textContent = money(cost);
      button.disabled = state.money < cost || (type === 'link' && !state.linkBuilt);
    });

    document.querySelectorAll('[data-speed]').forEach((button) => {
      button.classList.toggle('active', Number(button.dataset.speed) === state.simulationSpeed);
    });

    const pauseButton = document.querySelector('.speed-box > [data-speed="0"]');
    if (pauseButton) pauseButton.textContent = state.simulationSpeed === 0 ? '▶' : 'Ⅱ';
  }

  toast(message) {
    this.el.toast.textContent = message;
    this.el.toast.classList.add('show');
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.el.toast.classList.remove('show'), 1500);
  }
}
