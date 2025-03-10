SET SEARCH_PATH TO :'HIVESENSE_SCHEMA', public;


CREATE TEMP TABLE SEMANTIC_QUERIES (
    id SERIAL PRIMARY KEY,
    query TEXT
);

INSERT INTO SEMANTIC_QUERIES (query)
VALUES
    ('The sun sets behind the mountains, painting the sky in shades of orange and purple.'),
    ('Artificial intelligence is transforming various industries at an unprecedented pace.'),
    ('Water boils at 100 degrees Celsius under standard atmospheric pressure.'),
    ('The book was left open on the table, its pages fluttering in the evening breeze.'),
    ('She enjoys hiking through the dense forests during autumn.'),
    ('Quantum computing has the potential to revolutionize cryptographic security.'),
    ('A well-balanced diet is crucial for maintaining good health and well-being.'),
    ('The museum exhibits artifacts from ancient civilizations across different continents.'),
    ('He spent hours deciphering the intricate patterns in the old manuscript.'),
    ('The concept of infinity has fascinated mathematicians and philosophers alike.'),
    ('Solar panels convert sunlight into electricity using photovoltaic cells.'),
    ('The spacecraft successfully landed on Mars, marking a new era in space exploration.'),
    ('Music has the power to evoke deep emotions and memories.'),
    ('The economic impact of inflation is felt by businesses and consumers alike.'),
    ('A well-trained neural network can recognize complex patterns in vast datasets.'),
    ('The cat watched the fish swim lazily in the aquarium.'),
    ('Marine biodiversity is essential for the stability of oceanic ecosystems.'),
    ('The engineer designed a bridge capable of withstanding strong earthquakes.'),
    ('He meticulously arranged the chess pieces before making his first move.'),
    ('Blockchain technology ensures data integrity through decentralized verification.'),
    ('The painter captured the essence of the bustling city in his artwork.'),
    ('The formula for calculating the area of a circle is πr².'),
    ('Renewable energy sources are key to reducing carbon emissions globally.'),
    ('The student revised his thesis multiple times before submitting it.'),
    ('A black hole is a region in space where gravity is so strong that nothing can escape.'),
    ('The software engineer optimized the algorithm for faster processing times.'),
    ('Historical records provide insights into the evolution of human societies.'),
    ('The chef prepared a gourmet meal using locally sourced ingredients.'),
    ('His dedication to scientific research led to groundbreaking discoveries.'),
    ('The detective carefully examined the crime scene for clues.'),
    ('The orchestra played a mesmerizing symphony that captivated the audience.'),
    ('A telescope allows us to observe distant celestial bodies in the universe.'),
    ('The bridge spans across the river, connecting two bustling cities.'),
    ('Genetic engineering has opened new possibilities in medicine and agriculture.'),
    ('The butterfly emerged from its chrysalis, revealing vibrant wings.'),
    ('The philosopher pondered the meaning of existence under the starlit sky.'),
    ('Advancements in robotics are reshaping industrial automation.'),
    ('He solved the complex mathematical equation with remarkable ease.'),
    ('The ancient ruins tell the story of a lost civilization.'),
    ('An ecosystem is a delicate balance of interconnected living organisms.'),
    ('The company implemented a new cybersecurity framework to protect its data.'),
    ('The patient underwent a successful heart transplant operation.'),
    ('She recited a beautiful poem that left the audience in awe.'),
    ('The stock market fluctuates based on economic and geopolitical factors.'),
    ('Bioluminescent organisms produce light through chemical reactions.'),
    ('The submarine explored the uncharted depths of the ocean.'),
    ('The bird built its nest high up in the oak tree.'),
    ('The architect designed a sustainable building with energy-efficient features.'),
    ('The festival celebrated cultural diversity with music, dance, and cuisine.'),
    ('The scientific community debates the ethical implications of cloning.'),
    ('He spent years perfecting his craft as a master violinist.'),
    ('Astronomers discovered a new exoplanet orbiting a distant star.'),
    ('The mathematician proved a long-standing theorem that puzzled scholars.'),
    ('The river meanders through the valley, nourishing the fertile land.'),
    ('Social media has revolutionized the way people communicate and interact.'),
    ('The author weaves intricate narratives that captivate readers.'),
    ('He developed a breakthrough technology that enhances battery efficiency.'),
    ('The theater production featured an outstanding performance by the cast.'),
    ('Nanotechnology is making advancements in medical treatments and materials.'),
    ('The mountain climbers reached the summit after a grueling ascent.'),
    ('The detective uncovered a hidden passage leading to a secret chamber.'),
    ('Economic policies have a direct impact on the cost of living.'),
    ('The biologist studied the behavioral patterns of migratory birds.'),
    ('A sudden power outage plunged the city into darkness.'),
    ('The ship sailed across the Atlantic, braving the harsh storms.'),
    ('Digital currencies are reshaping the global financial landscape.'),
    ('The experiment yielded unexpected results, leading to further research.'),
    ('The symphony orchestra performed a classical masterpiece flawlessly.'),
    ('Meteorologists use satellite imagery to predict weather patterns.'),
    ('The scientist formulated a hypothesis based on the observed data.'),
    ('The rise of artificial intelligence raises ethical and regulatory concerns.'),
    ('The old lighthouse guided ships safely through the rocky coastline.'),
    ('The drone captured breathtaking aerial footage of the landscape.'),
    ('The robot navigated the obstacle course with precision.'),
    ('A healthy work-life balance is essential for long-term well-being.'),
    ('The spacecraft entered orbit around the distant exoplanet.'),
    ('The engineer designed a more efficient solar panel system.'),
    ('The novel explores themes of identity, love, and redemption.'),
    ('The city’s infrastructure underwent significant modernization.'),
    ('The athlete broke a world record in the marathon event.'),
    ('The ocean tides are influenced by the gravitational pull of the moon.'),
    ('The artificial intelligence system analyzed vast amounts of data.'),
    ('The botanist discovered a new species of rare orchid.'),
    ('The museum houses an extensive collection of rare artifacts.'),
    ('The astronaut conducted experiments aboard the International Space Station.'),
    ('The programmer optimized the database queries for better performance.'),
    ('The economic recession had long-lasting effects on employment rates.'),
    ('The invention of the printing press revolutionized knowledge dissemination.'),
    ('The coral reef is home to diverse marine life forms.'),
    ('The ancient manuscript contained forgotten knowledge of past civilizations.'),
    ('The satellite transmitted real-time images of Earth’s surface.'),
    ('The team developed an innovative solution to a complex problem.'),
    ('A well-trained dog can assist people with disabilities effectively.'),
    ('The discovery of a new element expanded the periodic table.'),
    ('A sustainable lifestyle helps reduce the impact on the environment.'),
    ('The new law aims to protect endangered species from extinction.');


WITH nearest_posts_id AS (
	SELECT sq.id, hivesense_app.find_nearest_posts(sq.query) as nearest_post_id, sq.query
	FROM SEMANTIC_QUERIES sq
), query_and_link AS (
		SELECT
              (npid.nearest_post_id).similarity_order
			,  npid.query
			, 'https://hive.blog/@' || ha.name || '/' ||  hpd.permlink as link
		FROM nearest_posts_id npid
		JOIN hivemind_app.hive_posts as hp ON hp.id = (npid.nearest_post_id).post_id
		JOIN hivemind_app.hive_accounts ha ON ha.id = hp.author_id
		JOIN hivemind_app.hive_permlink_data hpd ON hpd.id = hp.permlink_id
) SELECT JSONB_AGG( qal.* ORDER BY qal.similarity_order ) FROM query_and_link qal;

