// The fare list as shown: airlines, flight times and the round-trip fare of the first results.
const lines = document.body.innerText.split('\n').map(s => s.trim()).filter(Boolean);
const time = /^(\d\d:\d\d)([A-Z]{3})$/;
const skip = /이벤트|혜택|직항|경유|카드|적립|할인|로그인|^왕복$|원~$/;
const results = [];
let airlines = [], times = [];
for (let i = 0; i < lines.length && results.length < (args.limit || 5); i++) {
  const line = lines[i], next = lines[i + 1] || '';
  const t = line.match(time);
  if (t) { times.push(t[1] + ' ' + t[2]); continue; }
  const before = time.test(next) || (skip.test(next) && time.test(lines[i + 2] || ''));
  if (before && !skip.test(line) && !/\d/.test(line)) { airlines.push(line); continue; }
  if (line === '왕복' && /^[\d,]+$/.test(next) && times.length >= 4) {
    results.push({ airlines: [...new Set(airlines)], out: times.slice(0, 2), back: times.slice(2, 4), fare: next + '원' });
    airlines = []; times = [];
  }
}
return results;
