import tornado.gen
import tornado.web
from datetime import datetime as dt

from common.web import requestsManager
from constants import exceptions
from helpers import replayHelper
from common.sentry import sentry
from objects import glob

MODULE_NAME = "get_full_replay"
class handler(requestsManager.asyncRequestHandler):
    """
    Handler for /replay/
    """
    @tornado.web.asynchronous
    @tornado.gen.engine
    @sentry.captureTornado
    def asyncGet(self, replayID):
        relax = int(replayID) < 500000000
        replay = replayHelper.buildFullReplay(scoreID=replayID, relax=relax)

        if replay:
            self.write(replay)
            self.add_header("Content-type", "application/octet-stream")
            self.set_header("Content-length", len(replay))
            self.set_header("Content-Description", "File Transfer")

            q = glob.db.fetch(
                "SELECT beatmaps.song_name,users.username,scores{_relax}.time FROM scores{_relax} " \
                "LEFT JOIN beatmaps ON scores{_relax}.beatmap_md5=beatmaps.beatmap_md5 "            \
                "LEFT JOIN users ON scores{_relax}.userid=users.id "                                \
                "WHERE scores{_relax}.id=%s".format(_relax = '_relax' if relax else ''), [replayID])

            self.set_header("Content-Disposition", f'attachment; filename="{q["username"]} - {q["song_name"]} ({dt.fromtimestamp(q["time"]).strftime("%Y-%m-%d")}).osr"')
        else:
            self.write("Sorry, that replay no longer seems to exist on osu!Akatsuki's servers!")