import logging
from typing import Annotated

from fastapi import APIRouter, HTTPException, Depends

from app.database import database

router = APIRouter()
logger = logging.getLogger(__name__)

# protect a route by requiring the current user
@router.get("/helloworld", status_code=200)
async def get_hello_world():
    return {"message": "Hello, world!"}
