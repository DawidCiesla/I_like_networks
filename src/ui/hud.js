import {
  ECONOMY,
  getAddClientCost,
  getBottleneck,
  getIncomePerSecond,
  getLatencyMs,
  getPacketLossPercent,
  getQueueFillRatio,
  getThroughputMbps,
  getTotalDemandMbps,
  getUpgradeCost,
} from '../simulation/model.js';

const compact = (value) => {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 0 : 1)}m`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value >= 10_000 ? 0 : 1)}k`;
  return value.toFixed(value < 100 ? 1 : 0);
};

const money = (value) => `$${compact(value)}`;

export class Hud {
  constructor({ onConnect, onBuildSwitch, onAddClient, onUpgrade, onSpeed, onReset }) {
    this.el = {
      money: document.querySelector('#money-value'),
      throughput: document.querySelector('#throughput-value'),
      throughputStat: document.querySelector('#throughput-stat'),
      income: document.querySelector('#income-value'),
      objective: document.querySelector('#objective-text'),
      connect: document.querySelector('#connect-button'),
      connectSubtitle: document.querySelector('#connect-subtitle'),
      connectCost: document.querySelector('#connect-cost'),
      switchButton: document.querySelector('#switch-button'),
      switchSubtitle: document.querySelector('#switch-subtitle'),
      switchCost: document.querySelector('#switch-cost'),
      addClientButton: document.querySelector('#add-client-button'),
      addClientCost: document.querySelector('#add-client-cost'),
      clientCount: document.querySelector('#client-count-text'),
      demand: document.querySelector('#demand-value'),
      queue: document.querySelector('#queue-value'),
      latency: document.querySelector('#latency-value'),
      loss: document.querySelector('#loss-value'),
      bottleneck: document.querySelector('#bottleneck-value'),
      toast: document.querySelector('#toast'),
      reset: document.querySelector('#reset-button'),
    };

    this.el.connect.addEventListener('click', onConnect);
    this.el.switchButton.addEventListener('click', onBuildSwitch);
    this.el.addClientButton.addEventListener('click', onAddClient);

    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      button.addEventListener('click', () => onUpgrade(button.dataset.upgrade));
    });

    const pauseButton = document.querySelector('.speed-box > [data-speed="0"]');
    pauseButton?.addEventListener('click', () => onSpeed(this.currentSpeed === 0 ? 1 : 0));

    document.querySelectorAll('.speed-popover [data-speed]').forEach((button) => {
      button.addEventListener('click', () => onSpeed(Number(button.dataset.speed)));
    });

    this.el.reset.addEventListener('click', onReset);
  }

  render(state) {
    this.currentSpeed = state.simulationSpeed;

    const throughput = getThroughputMbps(state);
    const income = getIncomePerSecond(state);
    const demand = getTotalDemandMbps(state);
    const queueFill = getQueueFillRatio(state);
    const latency = getLatencyMs(state);
    const loss = getPacketLossPercent(state);
    const bottleneck = getBottleneck(state);
    const addClientCost = getAddClientCost(state);

    this.el.money.textContent = compact(state.money);
    this.el.throughput.textContent = `${throughput.toFixed(0)} Mb/s`;
    this.el.throughputStat.textContent = `${throughput.toFixed(0)} Mb/s`;
    this.el.income.textContent = `+${compact(income)}/s`;
    this.el.demand.textContent = `${demand.toFixed(0)} Mb/s`;
    this.el.queue.textContent = state.switch.built
      ? `${state.switch.queueMb.toFixed(0)} / ${state.switch.bufferMb} Mb`
      : '—';
    this.el.latency.textContent = state.linkBuilt ? `${latency.toFixed(latency < 100 ? 0 : 0)} ms` : '—';
    this.el.loss.textContent = state.switch.built ? `${loss.toFixed(loss < 1 ? 1 : 0)}%` : '—';
    this.el.bottleneck.textContent = bottleneck === 'none' ? 'NONE' : bottleneck.toUpperCase();

    this.el.queue.classList.toggle('metric-warning', queueFill >= 0.5 && queueFill < 0.9);
    this.el.queue.classList.toggle('metric-danger', queueFill >= 0.9);
    this.el.loss.classList.toggle('metric-danger', loss > 0);
    this.el.bottleneck.classList.toggle('metric-warning', !['none', 'offline'].includes(bottleneck));

    this.el.connect.disabled = state.linkBuilt || state.money < ECONOMY.ethernetBuildCost;
    this.el.connectSubtitle.textContent = state.linkBuilt ? 'Traffic online' : 'Client ↔ Server';
    this.el.connectCost.textContent = state.linkBuilt ? 'ONLINE' : money(ECONOMY.ethernetBuildCost);

    this.el.switchButton.disabled = !state.linkBuilt || state.switch.built || state.money < ECONOMY.switchBuildCost;
    this.el.switchSubtitle.textContent = state.switch.built
      ? `${state.switch.capacityMbps} Mb/s fabric · ${state.switch.bufferMb} Mb buffer`
      : 'Unlock multiple clients';
    this.el.switchCost.textContent = state.switch.built ? 'ONLINE' : money(ECONOMY.switchBuildCost);

    this.el.addClientButton.disabled = !state.switch.built
      || state.client.count >= ECONOMY.maxClients
      || state.money < addClientCost;
    this.el.clientCount.textContent = `${state.client.count} / ${ECONOMY.maxClients} connected`;
    this.el.addClientCost.textContent = state.client.count >= ECONOMY.maxClients ? 'MAX' : money(addClientCost);

    if (!state.linkBuilt) {
      this.el.objective.textContent = 'Connect the client to the server.';
    } else if (!state.switch.built) {
      this.el.objective.textContent = 'Install a switch to grow beyond one client.';
    } else if (loss > 0) {
      this.el.objective.textContent = 'Packets are being dropped. The queue is full.';
    } else if (queueFill >= 0.5) {
      this.el.objective.textContent = `Queue rising — ${bottleneck} is limiting the network.`;
    } else if (state.client.count < 3) {
      this.el.objective.textContent = 'Add clients until the first real bottleneck appears.';
    } else {
      this.el.objective.textContent = bottleneck === 'none'
        ? 'Network stable. Increase demand to stress it.'
        : `Bottleneck detected: ${bottleneck}.`;
    }

    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      const type = button.dataset.upgrade;
      const cost = getUpgradeCost(state, type);
      const costElement = button.querySelector('.row-cost strong');
      if (costElement) costElement.textContent = money(cost);

      const dependencyMissing =
        (type === 'link' && !state.linkBuilt)
        || ((type === 'switch' || type === 'buffer') && !state.switch.built);
      button.disabled = dependencyMissing || state.money < cost;
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
