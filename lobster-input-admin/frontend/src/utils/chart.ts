import { Chart, type ChartConfiguration } from 'chart.js/auto'

export const CHART_COLORS = [
  '#f2683c', '#4d90fe', '#2dd36f', '#f5a623', '#8b5cf6', '#ec4899', '#14b8a6',
]

const GRID = 'rgba(255,255,255,0.06)'
const AXIS = '#93a0b6'

export function destroyChart(chart: Chart | null): null {
  chart?.destroy()
  return null
}

export function mkLineChart(
  canvas: HTMLCanvasElement,
  labels: string[],
  data: number[],
  label = '',
): Chart {
  return new Chart(canvas, {
    type: 'line',
    data: {
      labels,
      datasets: [{
        label,
        data,
        backgroundColor: 'rgba(242,104,60,.16)',
        borderColor: '#f2683c',
        borderWidth: 2,
        fill: true,
        tension: 0.4,
        pointRadius: 0,
        pointHoverRadius: 4,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { ticks: { color: AXIS, maxTicksLimit: 8 }, grid: { color: GRID } },
        y: { ticks: { color: AXIS }, grid: { color: GRID } },
      },
    },
  })
}

export function mkDoughnutChart(
  canvas: HTMLCanvasElement,
  labels: string[],
  data: number[],
): Chart {
  return new Chart(canvas, {
    type: 'doughnut',
    data: {
      labels,
      datasets: [{ data, backgroundColor: CHART_COLORS, borderColor: '#141823', borderWidth: 2 }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      cutout: '62%',
      plugins: { legend: { labels: { color: AXIS, boxWidth: 12, usePointStyle: true, pointStyle: 'circle' } } },
    },
  } as ChartConfiguration<'doughnut'>)
}
