import { ECONOMY, getIncomePerSecond, getThroughputMbps, getUpgradeCost, getUtilization } from '../simulation/model.js';

const money = (value) => `$${value.toFixed(value < 100 ? 1 : 0)}`;

export class Hud {
  constructor({ onConnect, onUpgrade, onSpeed, onReset }) {
    this.el = {
      money: document.querySelector('#money-value'),
      throughput: document.querySelector('#throughput-value'),
      income: document.querySelector('#income-value'),
      objective: document.querySelector('#objective-text'),
      connect: document.querySelector('#connect-button'),
      demand: document.querySelector('#demand-value'),
      capacity: document.querySelector('#capacity-value'),
      server: document.querySelector('#server-value'),
      utilization: document.querySelector('#utilization-value'),
      toast: document.querySelector('#toast'),
      reset: document.querySelector('#reset-button'),
    };

    this.el.connect.addEventListener('click', onConnect);
    document.querySelectorAll('[data-upgrade]').forEach((button) => button.addEventListener('click', () => onUpgrade(button.dataset.upgrade)));
    document.querySelectorAll('[data-speed]').forEach((button) => button.addEventListener('click', () => onSpeed(Number(button.dataset.speed))));
    this.el.reset.addEventListener('click', onReset);
  }

  render(state) {
    const throughput = getThroughputMbps(state);
    const income = getIncomePerSecond(state);
    this.el.money.textContent = money(state.money);
    this.el.throughput.textContent = `${throughput.toFixed(1)} Mb/s`;
    this.el.income.textContent = `${money(income)}/s`;
    this.el.demand.textContent = `${state.client.trafficMbps} Mb/s`;
    this.el.capacity.textContent = state.linkBuilt ? `${state.link.capacityMbps} Mb/s` : '—';
    this.el.server.textContent = `${state.server.capacityMbps} Mb/s`;
    this.el.utilization.textContent = `${Math.round(getUtilization(state) * 100)}%`;

    this.el.connect.disabled = state.linkBuilt || state.money < ECONOMY.ethernetBuildCost;
    this.el.connect.innerHTML = state.linkBuilt ? 'ETHERNET CONNECTED <span>ONLINE</span>' : `CONNECT ETHERNET <span>${money(ECONOMY.ethernetBuildCost)}</span>`;
    this.el.objective.textContent = state.linkBuilt
      ? 'Traffic is flowing. Increase demand and capacity while keeping the path balanced.'
      : 'Connect the client to the server to start moving traffic.';

    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      const type = button.dataset.upgrade;
      const cost = getUpgradeCost(state, type);
      button.querySelector('strong').textContent = money(cost);
      button.disabled = state.money < cost || (type === 'link' && !state.linkBuilt);
    });
    document.querySelectorAll('[data-speed]').forEach((button) => {
      button.classList.toggle('active', Number(button.dataset.speed) === state.simulationSpeed);
    });
  }

  toast(message) {
    this.el.toast.textContent = message;
    this.el.toast.classList.add('show');
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.el.toast.classList.remove('show'), 1500);
  }
}
