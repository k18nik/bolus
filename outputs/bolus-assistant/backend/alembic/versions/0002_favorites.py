from alembic import op
import sqlalchemy as sa
revision='0002'
down_revision='0001'
branch_labels=None
depends_on=None
def upgrade():
    op.create_table('food_favorites',sa.Column('id',sa.String(36),primary_key=True),sa.Column('user_id',sa.String(36),sa.ForeignKey('users.id',ondelete='CASCADE'),nullable=False),sa.Column('food_key',sa.String(160),nullable=False),sa.Column('data',sa.JSON(),nullable=False),sa.UniqueConstraint('user_id','food_key'))
    op.create_index('ix_food_favorites_user_id','food_favorites',['user_id'])
def downgrade():op.drop_table('food_favorites')
