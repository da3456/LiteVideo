/**
 * 把服务端下发的相对发布时间（`videoRenderer.publishedTimeText`，如
 * "4 hours ago" / "vor 4 Stunden" / "hace 4 horas"）压成卡片用的短形
 * （"4h ago"），对齐网页端的显示。
 *
 * 只处理「数字 + 空格 + 单位词」这一对；前后残留的原文（"ago" / "il y a" /
 * "Streamed live" / "Premiered"）按原有空白位置拼回去。认不出来就原样返回，
 * 所以任何非标准文案（绝对日期、"Premiered Jan 5, 2024"）都不会被改坏。
 * 中日韩的文案本来就是数字直接贴单位（"4小时前"），这里不动它们。
 * 输出不引入新文案资源 —— 单位缩写按网页端惯例走 y/mo/w/d/h/min/s。
 */

const DIGITS: string = '0123456789';

/**
 * 整词匹配：单字母缩写和易歧义的短词做前缀会误判（"hace"、"Tag"、"meses"），
 * 所以这些只在整个单位 token 完全相等时才认。
 */
const EXACT_UNITS: string[][] = [
  ['s', 's'], ['h', 'h'], ['d', 'd'], ['w', 'w'], ['m', 'mo'], ['y', 'y'],
  ['min', 'min'], ['mins', 'min'], ['mo', 'mo'], ['sec', 's'], ['secs', 's'],
  ['hr', 'h'], ['hrs', 'h'], ['wk', 'w'], ['wks', 'w'], ['yr', 'y'], ['yrs', 'y'],
  ['an', 'y'], ['ans', 'y'], ['tag', 'd'], ['tags', 'd']
];

/** 前缀匹配的词干（含各语言的单复数变体，按词干归并）。 */
const UNIT_STEMS: string[][] = [
  // minute
  ['minut', 'min'], ['минут', 'min'], ['دقيق', 'min'],
  // second
  ['second', 's'], ['sekund', 's'], ['segund', 's'], ['секунд', 's'], ['ثاني', 's'],
  // hour
  ['hour', 'h'], ['hora', 'h'], ['heure', 'h'], ['stunde', 'h'], ['ora', 'h'],
  ['час', 'h'], ['ساع', 'h'],
  // day
  ['day', 'd'], ['día', 'd'], ['dia', 'd'], ['giorno', 'd'], ['jour', 'd'],
  ['ден', 'd'], ['день', 'd'], ['дня', 'd'], ['дней', 'd'], ['يوم', 'd'], ['أيام', 'd'],
  // week
  ['week', 'w'], ['woche', 'w'], ['semana', 'w'], ['settimana', 'w'], ['semaine', 'w'],
  ['недел', 'w'], ['أسبوع', 'w'], ['اسبوع', 'w'],
  // month
  ['month', 'mo'], ['monat', 'mo'], ['mes', 'mo'], ['mois', 'mo'], ['mese', 'mo'],
  ['mês', 'mo'], ['месяц', 'mo'], ['меся', 'mo'], ['شهر', 'mo'], ['أشهر', 'mo'],
  // year
  ['year', 'y'], ['jahr', 'y'], ['año', 'y'], ['ano', 'y'], ['anno', 'y'],
  ['année', 'y'], ['год', 'y'], ['лет', 'y'], ['سنة', 'y'], ['سنين', 'y']
];

function isDigit(ch: string): boolean {
  return ch.length > 0 && DIGITS.indexOf(ch) >= 0;
}

function isSpace(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n';
}

function findCompactUnit(rawUnit: string): string {
  const clean = rawUnit.toLowerCase().replace(/[.,;:!?]/g, '');
  if (clean.length === 0) {
    return '';
  }
  for (const entry of EXACT_UNITS) {
    if (entry[0] === clean) {
      return entry[1];
    }
  }
  for (const entry of UNIT_STEMS) {
    if (clean.startsWith(entry[0])) {
      return entry[1];
    }
  }
  return '';
}

export function compactPublishTime(text: string): string {
  const source = (text || '').trim();
  if (source.length === 0) {
    return '';
  }
  let digitStart = -1;
  for (let i = 0; i < source.length; i++) {
    if (isDigit(source.charAt(i))) {
      digitStart = i;
      break;
    }
  }
  if (digitStart < 0) {
    return source;
  }
  let digitEnd = digitStart;
  while (digitEnd < source.length && isDigit(source.charAt(digitEnd))) {
    digitEnd += 1;
  }
  const number = source.substring(digitStart, digitEnd);
  // 超过 4 位的数字基本是绝对日期/年份，不是相对时长。
  if (number.length > 4) {
    return source;
  }

  let unitStart = digitEnd;
  while (unitStart < source.length && isSpace(source.charAt(unitStart))) {
    unitStart += 1;
  }
  if (unitStart === digitEnd || unitStart >= source.length) {
    // 数字后紧跟非空白（"4K"、"2024年"）或没有下文，不动。
    return source;
  }
  let unitEnd = unitStart;
  while (unitEnd < source.length && !isSpace(source.charAt(unitEnd))) {
    unitEnd += 1;
  }
  const compact = findCompactUnit(source.substring(unitStart, unitEnd));
  if (compact.length === 0) {
    return source;
  }

  const before = source.substring(0, digitStart).trim();
  const after = source.substring(unitEnd).trim();
  const spaceBefore = digitStart > 0 && isSpace(source.charAt(digitStart - 1));
  const spaceAfter = unitEnd < source.length && isSpace(source.charAt(unitEnd));

  let result = number + compact;
  if (after.length > 0) {
    result += (spaceAfter ? ' ' : '') + after;
  }
  if (before.length > 0) {
    result = before + (spaceBefore ? ' ' : '') + result;
  }
  return result;
}
