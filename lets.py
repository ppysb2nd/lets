# General imports
from typing import List
from os import path, makedirs
from sys import exit
from multiprocessing.pool import ThreadPool

import tornado.gen
import tornado.httpserver
import tornado.ioloop
import tornado.web
from raven.contrib.tornado import AsyncSentryClient
import redis

from common.constants import bcolors
from common.db import dbConnector
from common.ddog import datadogClient
from common.log import logUtils as log
from common.redis import pubSub
from common.web import schiavo
from handlers import apiCacheBeatmapHandler
from handlers import apiPPHandler
from handlers import apiStatusHandler
from handlers import banchoConnectHandler
from handlers import checkUpdatesHandler
from handlers import defaultHandler
from handlers import downloadMapHandler
from handlers import emptyHandler
from handlers import rateHandler
from handlers import getFullReplayHandler
from handlers import getReplayHandler
from handlers import getScoresHandler
from handlers import getScreenshotHandler
from handlers import loadTestHandler
from handlers import mapsHandler
from handlers import osuSearchHandler
from handlers import osuSearchSetHandler
from handlers import osuSeasonal
from handlers import redirectHandler
from handlers import submitModularHandler
from handlers import uploadScreenshotHandler
from handlers import commentHandler
from handlers import lastfmHandler
from handlers import osuSessionHandler
from handlers import changelogHandler
from helpers import config
from helpers import consoleHelper
from common import generalUtils
from common import agpl
from objects import glob
from pubSubHandlers import beatmapUpdateHandler

def make_app():
    return tornado.web.Application([
        (r"/web/bancho_connect.php", banchoConnectHandler.handler),
        (r"/web/osu-osz2-getscores.php", getScoresHandler.handler),
        (r"/web/osu-submit-modular(-selector)?.php", submitModularHandler.handler),
        (r"/web/osu-getreplay.php", getReplayHandler.handler),
        (r"/web/osu-rate.php", rateHandler.handler),
        (r"/web/osu-screenshot.php", uploadScreenshotHandler.handler),
        (r"/web/osu-search.php", osuSearchHandler.handler),
        (r"/web/osu-search-set.php", osuSearchSetHandler.handler),
        (r"/web/check-updates.php", checkUpdatesHandler.handler),
        (r"/web/osu-comment.php", commentHandler.handler),
        (r"/web/osu-getseasonal.php", osuSeasonal.handler),
        (r"/ss/(.+)", getScreenshotHandler.handler),
        (r"/web/maps/(.+)", mapsHandler.handler),
        (r"/(s|d)/(.+)", downloadMapHandler.handler),
        (r"/web/replays/(.+)", getFullReplayHandler.handler),
        (r"/p/changelog", changelogHandler.handler),

        (r"/p/verify", redirectHandler.handler, dict(destination="https://osu.ppy.sb/index.php?p=2")),
        (r"/u/(.+)", redirectHandler.handler, dict(destination="https://osu.ppy.sb/u/{}")),

        (r"/(lets)?api/v1/status", apiStatusHandler.handler),
        (r"/(lets)?api/v1/pp", apiPPHandler.handler),
        (r"/(lets)?api/v1/cacheBeatmap", apiCacheBeatmapHandler.handler),

        (r"/web/lastfm.php", lastfmHandler.handler),
        (r"/web/osu-session.php", osuSessionHandler.handler),

        #(r"/loadTest", loadTestHandler.handler),

        # Not done yet
        (r"/web/osu-(addfavourite|checktweets|markasread|get-beatmap-topic).php", emptyHandler.handler)

    ], default_handler_class=defaultHandler.handler)


if __name__ == "__main__":
    try:
        agpl.check_license("ripple", "LETS")
    except agpl.LicenseError as e:
        print(str(e))
        exit(1)

    try:
        consoleHelper.printServerStartHeader(True)

        # Read config
        consoleHelper.printNoNl("> Reading config file... ")
        glob.conf = config.config("config.ini")

        if glob.conf.default:
            # We have generated a default config.ini, quit server
            consoleHelper.printWarning()
            consoleHelper.printColored("[!] config.ini not found. A default one has been generated.", bcolors.YELLOW)
            consoleHelper.printColored("[!] Please edit your config.ini and run the server again.", bcolors.YELLOW)
            exit()

        # If we haven't generated a default config.ini, check if it's valid
        if not glob.conf.checkConfig():
            consoleHelper.printError()
            consoleHelper.printColored("[!] Invalid config.ini. Please configure it properly", bcolors.RED)
            consoleHelper.printColored("[!] Delete your config.ini to generate a default one", bcolors.RED)
            exit()
        else:
            consoleHelper.printDone()

        # Create data/oppai maps folder if needed
        consoleHelper.printNoNl("> Checking folders... ")
        for i in (
            '.data',
            '.data/replays',
            '.data/screenshots',
            '.data/oppai',
            '.data/catch_the_pp',
            '.data/beatmaps'
        ):
            if not path.exists(i):
                makedirs(i, 0o770)
        consoleHelper.printDone()

        # Connect to db
        try:
            consoleHelper.printNoNl("> Connecting to MySQL database... ")
            glob.db = dbConnector.db(glob.conf.config["db"]["host"], glob.conf.config["db"]["username"], glob.conf.config["db"]["password"], glob.conf.config["db"]["database"], int(
                glob.conf.config["db"]["workers"]))
            consoleHelper.printNoNl(" ")
            consoleHelper.printDone()
        except:
            # Exception while connecting to db
            consoleHelper.printError()
            consoleHelper.printColored("[!] Error while connection to database. Please check your config.ini and run the server again", bcolors.RED)
            raise

        # Fetch newest top vn/rx top plays.
        try:
            consoleHelper.printNoNl("> Fetching values for highest vanilla & relax pp plays on osu!standard... ")

            top_plays = {
                'vanilla': glob.db.fetch("SELECT scores.pp FROM scores LEFT JOIN users ON scores.userid = users.id LEFT JOIN beatmaps ON scores.beatmap_md5 = beatmaps.beatmap_md5 WHERE scores.play_mode = 0 AND beatmaps.ranked = 2 AND users.privileges & 1 ORDER BY scores.pp DESC LIMIT 1"),
                'relax': glob.db.fetch("SELECT scores_relax.pp FROM scores_relax LEFT JOIN users ON scores_relax.userid = users.id LEFT JOIN beatmaps ON scores_relax.beatmap_md5 = beatmaps.beatmap_md5 WHERE scores_relax.play_mode = 0 AND beatmaps.ranked = 2 AND users.privileges & 1 ORDER BY scores_relax.pp DESC LIMIT 1")
            }

            glob.topPlays = (
                top_plays['vanilla']['pp'] if top_plays['vanilla'] else 0,
                top_plays['relax']['pp'] if top_plays['relax'] else 0
            )

            consoleHelper.printDone()
        except:
            consoleHelper.printError()
            consoleHelper.printColored("[!] Error while trying to fetch top plays for Vanilla & Relax osu!standard. Please check your database structure and run the server again", bcolors.RED)
            raise

        # Fetch mass-multiaccounters from config...
        try:
            consoleHelper.printNoNl("> Fetching mass-multiaccounters from config... ")
            glob.cursed = glob.conf.config['akatsuki']['cursed'].replace(' ', '').split(',')
            consoleHelper.printDone()
        except:
            consoleHelper.printError()
            consoleHelper.printColored("[!] Error while trying to fetch mass-multiaccounters from config. Please check your config.ini and run the server again", bcolors.RED)
            raise

        # Connect to redis
        try:
            consoleHelper.printNoNl("> Connecting to redis... ")
            glob.redis = redis.Redis(glob.conf.config["redis"]["host"], glob.conf.config["redis"]["port"], glob.conf.config["redis"]["database"], glob.conf.config["redis"]["password"])
            glob.redis.ping()
            consoleHelper.printNoNl(" ")
            consoleHelper.printDone()
        except:
            # Exception while connecting to db
            consoleHelper.printError()
            consoleHelper.printColored("[!] Error while connection to redis. Please check your config.ini and run the server again", bcolors.RED)
            raise

        # Empty redis cache
        try:
            glob.redis.eval("return redis.call('del', unpack(redis.call('keys', ARGV[1])))", 0, "lets:*")
        except redis.exceptions.ResponseError:
            # Script returns error if there are no keys starting with peppy:*
            pass

        # Save lets version in redis
        glob.redis.set("lets:version", glob.VERSION)

        # Create threads pool
        try:
            consoleHelper.printNoNl("> Creating threads pool... ")
            glob.pool = ThreadPool(int(glob.conf.config["server"]["threads"]))
            consoleHelper.printDone()
        except:
            consoleHelper.printError()
            consoleHelper.printColored("[!] Error while creating threads pool. Please check your config.ini and run the server again", bcolors.RED)

        # Check osuapi
        if not generalUtils.stringToBool(glob.conf.config["osuapi"]["enable"]):
            consoleHelper.printColored("[!] osu!api features are disabled. If you don't have a valid beatmaps table, all beatmaps will show as unranked", bcolors.YELLOW)
            if int(glob.conf.config["server"]["beatmapcacheexpire"]) > 0:
                consoleHelper.printColored("[!] IMPORTANT! Your beatmapcacheexpire in config.ini is > 0 and osu!api features are disabled.\nWe do not reccoment this, because too old beatmaps will be shown as unranked.\nSet beatmapcacheexpire to 0 to disable beatmap latest update check and fix that issue.", bcolors.YELLOW)

        # Set achievements version
        glob.redis.set("lets:achievements_version", glob.ACHIEVEMENTS_VERSION)
        consoleHelper.printColored("Achievements version is {}".format(glob.ACHIEVEMENTS_VERSION), bcolors.YELLOW)

        # Discord
        if generalUtils.stringToBool(glob.conf.config["discord"]["enable"]):
            glob.schiavo = schiavo.schiavo(glob.conf.config["discord"]["boturl"], "**lets**")
        else:
            consoleHelper.printColored("[!] Warning! Discord logging is disabled!", bcolors.YELLOW)

        # Check debug mods
        glob.debug = generalUtils.stringToBool(glob.conf.config["server"]["debug"])
        if glob.debug:
            consoleHelper.printColored("[!] Warning! Server running in debug mode!", bcolors.YELLOW)

        # Server port
        try:
            serverPort = int(glob.conf.config["server"]["port"])
        except:
            consoleHelper.printColored("[!] Invalid server port! Please check your config.ini and run the server again", bcolors.RED)

        # Make app
        glob.application = make_app()

        # Set up sentry
        try:
            glob.sentry = generalUtils.stringToBool(glob.conf.config["sentry"]["enable"])
            if glob.sentry:
                glob.application.sentry_client = AsyncSentryClient(glob.conf.config["sentry"]["dsn"], release=glob.VERSION)
            else:
                consoleHelper.printColored("[!] Warning! Sentry logging is disabled!", bcolors.YELLOW)
        except:
            consoleHelper.printColored("[!] Error while starting Sentry client! Please check your config.ini and run the server again", bcolors.RED)

        # Set up Datadog
        try:
            if generalUtils.stringToBool(glob.conf.config["datadog"]["enable"]):
                glob.dog = datadogClient.datadogClient(glob.conf.config["datadog"]["apikey"], glob.conf.config["datadog"]["appkey"])
            else:
                consoleHelper.printColored("[!] Warning! Datadog stats tracking is disabled!", bcolors.YELLOW)
        except:
            consoleHelper.printColored("[!] Error while starting Datadog client! Please check your config.ini and run the server again", bcolors.RED)

        # Connect to pubsub channels
        pubSub.listener(glob.redis, {
            "lets:beatmap_updates": beatmapUpdateHandler.handler(),
        }).start()

        # Server start message and console output
        consoleHelper.printColored("> L.E.T.S. is listening for clients on {}:{}...".format(glob.conf.config["server"]["host"], serverPort), bcolors.GREEN)
        log.logMessage("Server started!", discord="bunker", of="info.txt", stdout=False)

        # Start Tornado
        glob.application.listen(serverPort, address=glob.conf.config["server"]["host"])
        tornado.ioloop.IOLoop.instance().start()
    finally:
        # Perform some clean up
        print("> Disposing server... ")
        glob.fileBuffers.flushAll()
        consoleHelper.printColored("Goodbye!", bcolors.GREEN)
