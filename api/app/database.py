import databases
import sqlalchemy

from app.config import config

metadata = sqlalchemy.MetaData()

DATABASE_URL = config.DATABASE_URL
DB_FORCE_ROLL_BACK = config.DB_FORCE_ROLL_BACK

# Keep the synchronous engine on the driver declared in requirements. Newer
# SQLAlchemy versions can default bare postgresql:// URLs to psycopg (v3).
engine = sqlalchemy.create_engine(
	sqlalchemy.engine.make_url(DATABASE_URL).set(drivername="postgresql+psycopg2")
)

metadata.create_all(engine)

database = databases.Database(DATABASE_URL, force_rollback=DB_FORCE_ROLL_BACK, min_size=1, max_size=5)
