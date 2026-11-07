export const validAutoQuoteSeconds = value => typeof value === 'number' && Number.isFinite(value) && value >= 10 && value <= 86400;
export function parseAutoQuoteInterval(raw, unit = 'seconds') {
  const factors = {seconds: 1, minutes: 60, hours: 3600};
  if (typeof raw !== 'string' || !/^\d+(?:\.\d+)?$/.test(raw.trim()) || !Object.hasOwn(factors, unit)) throw Error('请输入有效的间隔，例如 30 秒或 1.5 分钟。');
  const seconds = Math.round(Number(raw.trim()) * factors[unit] * 1000) / 1000;
  if (!validAutoQuoteSeconds(seconds)) throw Error('自动语录间隔须在 10 秒至 24 小时之间。');
  return seconds;
}
