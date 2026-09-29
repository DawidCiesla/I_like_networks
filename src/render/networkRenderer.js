import { getThroughputMbps, getUtilization } from '../simulation/model.js';

const CLIENT = { x: -220, y: 0, w: 86, h: 64 };
const SERVER = { x: 220, y: 0, w: 82, h: 92 };

export class NetworkRenderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.camera = { x: 0, y: 0, zoom: 1 };
    this.pointer = { dragging: false, x: 0, y: 0, startX: 0, startY: 0 };
    this.selectedNode = null;
    this.time = 0;
    this.#bindInput();
    this.resize();
  }

  resize() {
    const rect = this.canvas.getBoundingClientRect();
    this.canvas.width = Math.max(1, Math.floor(rect.width * this.dpr));
    this.canvas.height = Math.max(1, Math.floor(rect.height * this.dpr));
  }

  #bindInput() {
    this.canvas.addEventListener('pointerdown', (e) => {
      this.pointer.dragging = true;
      this.pointer.x = e.clientX;
      this.pointer.y = e.clientY;
      this.pointer.startX = e.clientX;
      this.pointer.startY = e.clientY;
      this.canvas.setPointerCapture(e.pointerId);
    });
    this.canvas.addEventListener('pointermove', (e) => {
      if (!this.pointer.dragging) return;
      this.camera.x += (e.clientX - this.pointer.x) / this.camera.zoom;
      this.camera.y += (e.clientY - this.pointer.y) / this.camera.zoom;
      this.pointer.x = e.clientX;
      this.pointer.y = e.clientY;
    });
    this.canvas.addEventListener('pointerup', (e) => {
      const moved = Math.hypot(e.clientX - this.pointer.startX, e.clientY - this.pointer.startY);
      this.pointer.dragging = false;
      if (moved < 4) this.#selectAt(e.clientX, e.clientY);
    });
    this.canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      const factor = e.deltaY > 0 ? 0.9 : 1.1;
      this.camera.zoom = Math.min(2.2, Math.max(0.55, this.camera.zoom * factor));
    }, { passive: false });
    window.addEventListener('resize', () => this.resize());
  }

  #screenToWorld(clientX, clientY) {
    const rect = this.canvas.getBoundingClientRect();
    const sx = clientX - rect.left - rect.width / 2;
    const sy = clientY - rect.top - rect.height / 2;
    return { x: sx / this.camera.zoom - this.camera.x, y: sy / this.camera.zoom - this.camera.y };
  }

  #selectAt(clientX, clientY) {
    const p = this.#screenToWorld(clientX, clientY);
    const hit = (n) => p.x >= n.x - n.w/2 && p.x <= n.x + n.w/2 && p.y >= n.y - n.h/2 && p.y <= n.y + n.h/2;
    this.selectedNode = hit(CLIENT) ? 'client' : hit(SERVER) ? 'server' : null;
  }

  render(state, dt) {
    this.time += dt;
    const ctx = this.ctx;
    const w = this.canvas.width / this.dpr;
    const h = this.canvas.height / this.dpr;
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    this.#drawBackground(ctx, w, h);

    ctx.save();
    ctx.translate(w / 2, h / 2);
    ctx.scale(this.camera.zoom, this.camera.zoom);
    ctx.translate(this.camera.x, this.camera.y);
    if (state.linkBuilt) this.#drawLink(ctx, state);
    else this.#drawGhostLink(ctx);
    this.#drawClient(ctx, state);
    this.#drawServer(ctx, state);
    ctx.restore();
  }

  #drawBackground(ctx, w, h) {
    ctx.fillStyle = '#070b10';
    ctx.fillRect(0, 0, w, h);
    const spacing = 32;
    const ox = ((this.camera.x * this.camera.zoom) % spacing + spacing) % spacing;
    const oy = ((this.camera.y * this.camera.zoom) % spacing + spacing) % spacing;
    ctx.strokeStyle = 'rgba(112, 156, 172, 0.055)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = ox; x < w; x += spacing) { ctx.moveTo(x, 0); ctx.lineTo(x, h); }
    for (let y = oy; y < h; y += spacing) { ctx.moveTo(0, y); ctx.lineTo(w, y); }
    ctx.stroke();
  }

  #drawGhostLink(ctx) {
    ctx.save();
    ctx.setLineDash([6, 10]);
    ctx.strokeStyle = 'rgba(88,215,245,.18)';
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.moveTo(CLIENT.x + CLIENT.w/2, 0); ctx.lineTo(SERVER.x - SERVER.w/2, 0); ctx.stroke();
    ctx.restore();
  }

  #drawLink(ctx, state) {
    const x1 = CLIENT.x + CLIENT.w/2;
    const x2 = SERVER.x - SERVER.w/2;
    const utilization = getUtilization(state);
    ctx.strokeStyle = `rgba(88,215,245,${0.38 + utilization * 0.5})`;
    ctx.lineWidth = 2.4;
    ctx.beginPath(); ctx.moveTo(x1, 0); ctx.lineTo(x2, 0); ctx.stroke();

    const throughput = getThroughputMbps(state);
    const particleCount = throughput > 0 ? Math.min(16, Math.max(2, Math.ceil(throughput / 3))) : 0;
    for (let i = 0; i < particleCount; i++) {
      const t = (this.time * (0.25 + Math.min(throughput, 100) / 350) + i / particleCount) % 1;
      const x = x1 + (x2 - x1) * t;
      const pulse = 0.7 + Math.sin((t + this.time) * Math.PI * 2) * 0.3;
      ctx.fillStyle = `rgba(140,236,255,${0.65 + pulse * 0.35})`;
      ctx.fillRect(Math.round(x) - 2, -2, 4, 4);
    }

    ctx.fillStyle = 'rgba(113,145,157,.8)';
    ctx.font = '10px monospace';
    ctx.textAlign = 'center';
    ctx.fillText(`${throughput.toFixed(1)} Mb/s`, 0, -16);
  }

  #drawClient(ctx, state) {
    const selected = this.selectedNode === 'client';
    this.#nodeFrame(ctx, CLIENT, selected);
    ctx.strokeStyle = '#70dff6';
    ctx.lineWidth = 2;
    ctx.strokeRect(CLIENT.x - 22, -18, 44, 29);
    ctx.beginPath(); ctx.moveTo(CLIENT.x - 13, 17); ctx.lineTo(CLIENT.x + 13, 17); ctx.moveTo(CLIENT.x, 11); ctx.lineTo(CLIENT.x, 17); ctx.stroke();
    this.#nodeLabel(ctx, CLIENT.x, CLIENT.h/2 + 18, 'CLIENT', `${state.client.trafficMbps} Mb/s demand`);
  }

  #drawServer(ctx, state) {
    const selected = this.selectedNode === 'server';
    this.#nodeFrame(ctx, SERVER, selected);
    ctx.strokeStyle = '#8fe39d';
    ctx.lineWidth = 2;
    ctx.strokeRect(SERVER.x - 18, -32, 36, 64);
    for (let y = -20; y <= 20; y += 13) {
      ctx.beginPath(); ctx.moveTo(SERVER.x - 10, y); ctx.lineTo(SERVER.x + 6, y); ctx.stroke();
      ctx.fillStyle = '#8fe39d'; ctx.fillRect(SERVER.x + 10, y - 1, 3, 3);
    }
    this.#nodeLabel(ctx, SERVER.x, SERVER.h/2 + 18, 'SERVER', `${state.server.capacityMbps} Mb/s capacity`);
  }

  #nodeFrame(ctx, node, selected) {
    if (!selected) return;
    ctx.fillStyle = 'rgba(88,215,245,.05)';
    ctx.strokeStyle = 'rgba(88,215,245,.38)';
    ctx.lineWidth = 1;
    ctx.fillRect(node.x - node.w/2, node.y - node.h/2, node.w, node.h);
    ctx.strokeRect(node.x - node.w/2, node.y - node.h/2, node.w, node.h);
  }

  #nodeLabel(ctx, x, y, title, detail) {
    ctx.textAlign = 'center';
    ctx.font = '10px monospace';
    ctx.fillStyle = '#cfe8f0';
    ctx.fillText(title, x, y);
    ctx.font = '9px monospace';
    ctx.fillStyle = '#687b84';
    ctx.fillText(detail, x, y + 15);
  }
}
