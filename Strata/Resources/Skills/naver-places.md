---
name: naver-places
description: Find places in Korea (restaurants, cafes, bars, shops) on Naver Place with ratings and visitor reviews, show them on a map, and give Naver Map directions.
---

# Naver places

Use this for any request to find, compare or recommend places in Korea, to read what visitors say about a place, or to get directions there. Naver Place has the most complete Korean listings and visitor reviews.

Work with `browser_open` (opens a page and returns its text) and `run_skill_script` (runs one of the scripts below in that page by name, like `run_skill_script(skill: "naver-places", script: "LIST")`). The scripts return JSON.

## 1. Search for places

Write the query in Korean the way a person would type it into Naver: area + kind of place + what matters ("성수 조용한 카페", "합정 저녁", "강남역 회식 고깃집", "연남동 브런치 웨이팅 없는"). If the user wants places near them and has not named an area, call `current_location` first and use the locality it returns.

1. `browser_open` with `https://m.search.naver.com/search.naver?query=` + the URL-encoded query.
2. `run_skill_script` with the LIST script. It returns the places in the Naver Place block (ads are skipped): `name`, `category`, `placeId`, `rating` (별점, often null: Naver hides it for many restaurants), `reviewCount`, `status` (영업 중 / 영업 전 / 영업 종료 / 휴무), `distance`, `address` (area only), up to 3 short `reviews` snippets, and the place `url`.
3. For more than the first five or so, run the MORE script, then the LIST script again.

`distance` is measured from where Naver guesses the browser is (often central Seoul), not from the user. Do not quote it; when the user's location is known, judge distance from the coordinates instead.

LIST script:

```js script=LIST
// naver-places:list
const words = (el, withHidden) => {
  const out = [];
  const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  for (let n; (n = walk.nextNode());) {
    const p = n.parentElement;
    if (!p || p.closest("svg, style, script") || (!withHidden && p.closest(".place_blind"))) continue;
    const t = n.textContent.replace(/\s+/g, " ").trim();
    if (t) out.push(t);
  }
  return out.join(" ");
};
const byId = new Map();
for (const a of document.querySelectorAll('a[href*="place.naver.com/"]')) {
  const m = a.href.match(/place\.naver\.com\/([a-z]+)\/(\d{5,})(\/[a-z]*)?/i);
  if (!m || (m[3] && m[3] !== "/" && m[3] !== "/home")) continue;
  if (!byId.has(m[2])) byId.set(m[2], { type: m[1], anchors: [] });
  byId.get(m[2]).anchors.push(a);
}
const count = el => el.querySelectorAll('a[href*="place.naver.com/"]').length;
const places = [];
for (const [id, { type, anchors }] of byId) {
  const nameLink = anchors.find(a => words(a));
  if (!nameLink) continue;
  let item = nameLink.closest("li");
  if (!item) { item = nameLink; while (item.parentElement && count(item.parentElement) === count(item)) item = item.parentElement; }
  const parts = Array.from(nameLink.children).map(c => words(c)).filter(Boolean);
  const reviewLinks = Array.from(item.querySelectorAll('a[href*="/review/"]'));
  const bare = item.cloneNode(true);
  bare.querySelectorAll('a[href*="/review/"]').forEach(a => a.remove());
  const text = words(bare, true);
  const pick = (re, i = 0) => { const m = text.match(re); return m ? m[i] : null; };
  const num = re => { const v = pick(re, 1); return v ? parseFloat(v.replace(/,/g, "")) : null; };
  places.push({
    name: parts[0] || words(nameLink),
    category: parts.length > 1 ? parts[parts.length - 1] : null,
    placeId: id,
    rating: num(/별점\s*([\d.]+)/),
    reviewCount: num(/리뷰\s*([\d,]+)/),
    status: pick(/영업\s?(?:중|전|종료)|휴무|브레이크타임/),
    distance: pick(/(\d+(?:\.\d+)?\s?k?m)(?=\s|$)/i, 1),
    address: pick(/(?:서울|부산|대구|인천|광주|대전|울산|세종|경기|강원|충북|충남|전북|전남|경북|경남|제주)\S*(?:\s+\S+(?:시|군|구))+(?:\s+\S+(?:동|읍|면|가|리|로|길))?/),
    reviews: reviewLinks.map(a => words(a)).filter(t => t.length > 15).slice(0, 3),
    url: "https://m.place.naver.com/" + type + "/" + id + "/home"
  });
}
return JSON.stringify(places);
```

MORE script (opens the rest of the list):

```js script=MORE
// naver-places:more
const before = document.querySelectorAll('a[href*="place.naver.com/"]').length;
const button = Array.from(document.querySelectorAll("a, button")).find(e => /펼쳐서 더보기/.test(e.innerText || ""));
if (!button) return "No more results to open.";
button.click();
await new Promise(r => setTimeout(r, 2500));
return "Opened more results (" + before + " place links before, " + document.querySelectorAll('a[href*="place.naver.com/"]').length + " now). Run the LIST script again.";
```

## 2. Read a place's details

For each place worth recommending (usually 3 to 5), `browser_open` `https://m.place.naver.com/place/{placeId}/home`, then `run_skill_script` with the DETAILS script. It returns `name`, `category`, the full `address`, `lat` and `lng`, `rating` (visitor review score), `visitorReviews`, `blogReviews`, `phone`, a one-line `summary`, and the `topKeywords` visitors voted for (like "집중하기 좋아요 (252)").

DETAILS script:

```js script=DETAILS
// naver-places:details
const s = window.__APOLLO_STATE__ || {};
const key = Object.keys(s).find(k => k.startsWith("PlaceDetailBase:"));
const b = key ? s[key] : null;
if (!b) return JSON.stringify({ error: "no place data on this page; read the browser_open text instead", url: location.href });
const statsKey = Object.keys(s).find(k => k.startsWith("VisitorReviewStatsResult:"));
const stats = statsKey ? s[statsKey] : null;
const themes = ((stats && stats.analysis && stats.analysis.votedKeyword && stats.analysis.votedKeyword.details) || [])
  .slice(0, 5).map(d => d.displayName + " (" + d.count + ")");
return JSON.stringify({
  placeId: b.id, name: b.name, category: b.category,
  address: b.roadAddress || b.address || null,
  lat: b.coordinate ? parseFloat(b.coordinate.y) : null,
  lng: b.coordinate ? parseFloat(b.coordinate.x) : null,
  rating: b.visitorReviewsScore || null,
  visitorReviews: b.visitorReviewsTotal || null,
  blogReviews: b.cafeBlogReviewsTotal || null,
  phone: b.virtualPhone || b.phone || null,
  summary: (b.microReviews || []).join(" / ") || null,
  topKeywords: themes
});
```

## 3. Read visitor reviews

To check what people actually say (quiet? good for work? long waits?), `browser_open` `https://m.place.naver.com/place/{placeId}/review/visitor`, then `run_skill_script` with the REVIEWS script. It returns up to 15 recent reviews: `rating`, `visited` (date), the `keywords` the visitor picked, and the review `text` (cut to 400 characters).

REVIEWS script:

```js script=REVIEWS
// naver-places:reviews
const s = window.__APOLLO_STATE__ || {};
const reviews = Object.keys(s).filter(k => k.startsWith("VisitorReview:")).map(k => s[k])
  .filter(r => r && r.body)
  .map(r => ({
    rating: r.rating || null,
    visited: r.visited || null,
    keywords: (r.votedKeywords || []).map(v => v.name),
    text: r.body.replace(/\s+/g, " ").trim().slice(0, 400)
  }));
if (!reviews.length) return JSON.stringify({ error: "no reviews found in page data; read the browser_open text instead", url: location.href });
return JSON.stringify(reviews.slice(0, 15));
```

Quote reviewers only with their own words (keep the Korean; translate in your answer if the user writes in another language). Never make up a review or a rating.

## 4. Show the results

Call `show_places` with the places you recommend, best first, so the user sees them on a map with cards. For each place pass `name`, `category`, `rating`, `reviewCount`, `address`, `lat` and `lng` (from DETAILS), `placeId`, a one-sentence `note` on why it fits the request (in the user's language), and a short `quote` from a review that backs it up. Give a `title` such as "Quiet cafes in Seongsu". Then write a short answer; the map already carries the details, so do not repeat every field.

## 5. Directions

The cards in `show_places` already have Naver Map buttons for walking, transit, driving and cycling. If the user asks for a link, use these (URL-encode the name):

- Walk: `nmap://route/walk?dlat={lat}&dlng={lng}&dname={name}&appname=cc.coolservices.strata`
- Transit: `nmap://route/public?dlat={lat}&dlng={lng}&dname={name}&appname=cc.coolservices.strata`
- Car: `nmap://route/car?dlat={lat}&dlng={lng}&dname={name}&appname=cc.coolservices.strata`
- Bike: `nmap://route/bicycle?dlat={lat}&dlng={lng}&dname={name}&appname=cc.coolservices.strata`
- The place itself: `nmap://place?lat={lat}&lng={lng}&name={name}&appname=cc.coolservices.strata`

Without a start (`slat`, `slng`, `sname`) Naver Map routes from the user's current location. On the web, a place opens at `https://map.naver.com/p/entry/place/{placeId}`.

## When a script returns nothing

Naver changes its pages now and then. If a script returns `[]` or an error:

- Read the `browser_open` text instead. A search page lists each place as its name and category, then lines like "영업 중", "별점 4.92", "리뷰 2,684", and review snippets; ads are marked "광고". A place page lists the address after "주소" and reviews after "리뷰".
- Write a small `browser_eval` of your own that returns only what you need (for example the text of the list items), rather than reading the whole page again.
- To get somewhere the scripts don't cover (a tab like "리뷰", "더보기", a filter), act on the page with the index tools: `browser_click` an [index] from the page state, `browser_find` to locate text.
- Without coordinates, still call `show_places` with names and addresses: the app finds them on the map.

If a page mentions "자동입력 방지" or a captcha, Naver is blocking automated access: stop and tell the user, and suggest searching in the Naver Map app.
