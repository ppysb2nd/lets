from os import path

import tornado.gen
import tornado.web

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from common.constants import mods
from objects import glob
from objects import rxscore
from common.sentry import sentry

MODULE_NAME = "get_replay"


class handler(requestsManager.asyncRequestHandler):
    """
	Handler for osu-getreplay.php
	"""

    @tornado.web.asynchronous
    @tornado.gen.engine
    @sentry.captureTornado
    def asyncGet(self):
        try:

            # Check arguments
            if not requestsManager.checkArguments(self.request.arguments, ["c", "u", "h"]):
                raise exceptions.invalidArgumentsException(MODULE_NAME)

            # Get arguments
            username = self.get_argument("u")
            replayID = self.get_argument("c")

            # Login check
            userID = userUtils.getID(username)
            if userID == 0:
                raise exceptions.loginFailedException(MODULE_NAME, userID)
            if not userUtils.checkLogin(userID, self.get_argument("h"), self.getRequestIP()):
                raise exceptions.loginFailedException(MODULE_NAME, username)

            replayData = glob.db.fetch(
                "SELECT scores.userid, scores.play_mode, scores.mods, users.username AS uname FROM scores LEFT JOIN users ON scores.userid = users.id WHERE scores.id = %s LIMIT 1",
                [replayID])
            fileName = f".data/replays/replay_{replayID}.osr"

            # If replay doesn't match its owner, its a relax replay
            # I know it is slow but I have no other way
            if replayData is None or replayData["uname"] != username:
                replayData = glob.db.fetch(
                    "SELECT scores_relax.userid, scores_relax.play_mode, scores_relax.mods, users.username AS uname FROM scores_relax LEFT JOIN users ON scores_relax.userid = users.id WHERE scores_relax.id = %s LIMIT 1",
                    [replayID])
                fileName = f".data/rx_replays/replay_{replayID}.osr"

            # Increment 'replays watched by others' if needed
            if replayData:
                if username != replayData["uname"]:
                    userUtils.incrementReplaysWatched(replayData["userid"], replayData["play_mode"], replayData["mods"])

            log.info(f"Serving replay_{replayID}.osr")

            if path.isfile(fileName):
                with open(fileName, "rb") as f:
                    fileContent = f.read()
                self.write(fileContent)
            else:
                self.write("")
                log.warning(f"Replay {replayID} doesn't exist in {fileName}.")

        except exceptions.invalidArgumentsException:
            pass
        except exceptions.loginFailedException:
            pass
