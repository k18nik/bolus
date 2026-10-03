"""Bind saved credentials and consent to an explicit AI provider."""
from alembic import op
import sqlalchemy as sa
revision='0004_ai_provider'
down_revision='0003_ai_and_batches'
branch_labels=None
depends_on=None
def upgrade():
    op.add_column('ai_settings',sa.Column('provider',sa.String(20),nullable=False,server_default='openai'))
    op.add_column('ai_settings',sa.Column('last_check',sa.JSON(),nullable=True))
    op.add_column('ai_insights',sa.Column('provider',sa.String(20),nullable=False,server_default='openai'))
def downgrade():
    op.drop_column('ai_settings','provider');op.drop_column('ai_settings','last_check');op.drop_column('ai_insights','provider')
