-- Root posts for the `embed-search` check (.aidev/run-checks.sh) in the AIDEV test
-- stack's empty hivemind: the rows hivesense_app.posts_in_range and the search
-- endpoints join on. Three long posts on distinct topics (witness voting, mountain
-- hiking, a tomato sauce for pasta), a second long post on the pasta topic by
-- another author, and one single-sentence post (title only) below the
-- --min-token-threshold `embed-search` installs with (200; see run-checks.sh).
-- .aidev/hivesense_smoke.py's EMBEDDED_CHECKS names them by author/permlink.
--
-- The ids are far above anything hivemind's sequences hand out in this stack, and
-- deliberately not in ranking order (account and post id order would otherwise
-- tie-break a ranking computed from broken embeddings into the expected one).
-- Re-running replaces the rows. Blocks 101-105 hold nothing else.
BEGIN;

-- Written outside hivemind's block processing: none of its table triggers
-- (HAF fork bookkeeping, deferred foreign keys) may fire on these rows.
SET LOCAL session_replication_role = replica;

DELETE FROM hivemind_app.hive_post_data
WHERE id BETWEEN 900101 AND 900105;
DELETE FROM hivemind_app.hive_posts
WHERE id BETWEEN 900101 AND 900105;
DELETE FROM hivemind_app.hive_permlink_data
WHERE id BETWEEN 900101 AND 900105;
DELETE FROM hivemind_app.hive_accounts
WHERE id BETWEEN 9101 AND 9105;

INSERT INTO hivemind_app.hive_accounts (id, name, created_at) VALUES
(9101, 'aidev-witness', '2026-01-01 00:00:00'),
(9102, 'aidev-hiker', '2026-01-01 00:00:00'),
(9103, 'aidev-chef', '2026-01-01 00:00:00'),
(9104, 'aidev-shorty', '2026-01-01 00:00:00'),
(9105, 'aidev-cook', '2026-01-01 00:00:00');

INSERT INTO hivemind_app.hive_permlink_data (id, permlink) VALUES
(900101, 'why-your-witness-votes-matter'),
(900102, 'three-days-on-the-alpine-ridge'),
(900103, 'slow-simmered-tomato-sauce-for-pasta'),
(900104, 'back-from-the-market'),
(900105, 'fresh-egg-pasta-with-tomato-basil-sauce');

INSERT INTO hivemind_app.hive_posts (
    id, root_id, parent_id, author_id, permlink_id, category_id, created_at, depth, block_num, block_num_created
) VALUES
(900101, 900101, 0, 9101, 900101, 0, '2026-01-01 00:05:03', 0, 101, 101),
(900102, 900102, 0, 9102, 900102, 0, '2026-01-01 00:05:06', 0, 102, 102),
(900103, 900103, 0, 9103, 900103, 0, '2026-01-01 00:05:09', 0, 103, 103),
(900104, 900104, 0, 9104, 900104, 0, '2026-01-01 00:05:12', 0, 104, 104),
(900105, 900105, 0, 9105, 900105, 0, '2026-01-01 00:05:15', 0, 105, 105);

INSERT INTO hivemind_app.hive_post_data (id, title, body, json) VALUES
(
    900101,
    'Why your witness votes matter on the Hive blockchain',
    'Witnesses are the block producers of the Hive blockchain. Every three seconds one of them signs a new block, and the
twenty witnesses with the most stake-weighted votes take turns producing blocks in every round, with one more backup
witness scheduled by rotation. Each account can vote for up to thirty witnesses, and the weight of those votes is the
account''s Hive Power, so staking HIVE is what gives you a say in who secures the chain.

Witnesses do much more than produce blocks. They run the consensus nodes, publish the HBD price feed that the
blockchain uses for conversions, and signal which hardfork they support, so a protocol upgrade only activates when a
supermajority of the top witnesses runs the new version. A witness that misses blocks, publishes a stale price feed or
runs outdated software weakens the network.

Review your witness votes regularly. Check each witness''s missed block count, feed age and running version on a block
explorer, read their witness posts, and remove votes from witnesses who stopped maintaining their nodes. If you do not
have time to follow governance, set a witness voting proxy: your stake then follows the votes of an account you trust.
Decentralized governance only works when stakeholders actually vote.',
    '{}'
),
(
    900102,
    'Three days on the alpine ridge: a mountain hiking trip report',
    'We started the hike at dawn from the valley trailhead, carrying three days of food, water filters and warm layers.
The trail climbed steeply through pine forest and then switchbacked across open meadows full of wildflowers. By noon we
reached the first mountain pass at two thousand four hundred meters, where the wind picked up and we stopped for lunch
behind a boulder.

The second day was the crux of the trip: a long exposed ridge walk towards the summit. The path narrowed to a rocky
crest with steep drops on both sides, and we kept a careful pace, testing every foothold with our trekking poles.
Clouds built up over the peaks in the afternoon, so we turned around below the summit and descended to the alpine hut
before the thunderstorm arrived. Turning back is never a failure in the mountains.

On the last day we hiked down past a glacier lake, our knees aching on the steep descent. Good boots, broken in before
the trip, made all the difference on the loose scree. Tips for anyone planning this route: start early, check the
mountain weather forecast twice a day, pack a map and compass, and book the hut in advance during the summer season.',
    '{}'
),
(
    900103,
    'Slow-simmered tomato sauce for pasta, the way my grandmother cooked it',
    'This is the tomato sauce recipe I cook every Sunday, and it turns a plate of pasta into a real Italian dinner. You
need two cans of whole peeled San Marzano tomatoes, a good glug of extra virgin olive oil, four cloves of garlic, one
small onion, a handful of fresh basil, salt and a pinch of sugar.

Warm the olive oil in a heavy pan over low heat and gently fry the finely chopped onion until it is soft and sweet,
then add the sliced garlic and cook it for one more minute without letting it brown. Crush the tomatoes by hand into
the pan, add the salt and the sugar, and let the sauce simmer very slowly, uncovered, for at least an hour. Stir it from
time to time so it does not stick, and add a splash of water if it gets too thick.

At the end, tear in the basil leaves and taste for seasoning. Cook the spaghetti in plenty of salted boiling water until
al dente, keep a cup of the starchy pasta water, and toss the drained pasta in the pan with the tomato sauce, loosening
it with a little of that water. Serve the pasta right away with freshly grated parmesan cheese and more olive oil.',
    '{}'
),
(
    900104,
    'Back from the market, long queue today but worth it',
    '',
    '{}'
),
(
    900105,
    'Fresh egg pasta with a quick tomato and basil sauce',
    'Making fresh pasta at home is easier than most people think, and it is the best partner for a simple tomato sauce.
For two people, cook with two hundred grams of flour and two eggs. Pile the flour on the board, make a well, crack the
eggs into it and mix them in with a fork, then knead the dough for ten minutes until it is smooth and elastic. Wrap it
and let it rest for half an hour.

While the dough rests, make the sauce. Heat olive oil in a pan, add a crushed clove of garlic and a pinch of chili
flakes, then pour in a can of chopped tomatoes with a little salt. Let the tomato sauce simmer for twenty minutes until
it thickens, and finish it with plenty of torn fresh basil.

Roll the pasta dough out thinly with a rolling pin or a pasta machine, dust it with flour and cut it into ribbons of
tagliatelle. Fresh pasta cooks in two or three minutes in salted boiling water. Drain it, toss it straight into the
pan with the tomato and basil sauce and a spoonful of the cooking water, and serve it with grated parmesan. A simple
Italian recipe for a weeknight dinner.',
    '{}'
);

COMMIT;
