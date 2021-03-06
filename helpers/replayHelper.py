from os import path

from common import generalUtils
from common.log import logUtils as log
from constants import exceptions, dataTypes
from helpers import binaryHelper
from objects import glob
from common.constants import mods

def buildFullReplay(scoreID=None, scoreData=None, rawReplay=None, relax=False):
    if all(not v for v in (scoreID, scoreData)) or all(v for v in (scoreID, scoreData)):
        raise AttributeError("Either scoreID or scoreData must be provided, not neither or both")

    if not scoreData:
        scoreData = glob.db.fetch(
            "SELECT scores{_relax}.*, users.username FROM scores{_relax} LEFT JOIN users ON scores{_relax}.userid = users.id WHERE scores{_relax}.id = %s".format(_relax='_relax' if relax else ''),
            [scoreID]
        )
    else:
        scoreID = scoreData["id"]
    if not scoreData or not scoreID:
        raise exceptions.scoreNotFoundError()

    # Calculate missing replay data
    rank = generalUtils.getRank(int(scoreData["play_mode"]), int(scoreData["mods"]), int(scoreData["accuracy"]),
                                int(scoreData["300_count"]), int(scoreData["100_count"]), int(scoreData["50_count"]),
                                int(scoreData["misses_count"]))
    magicHash = generalUtils.stringMd5(
        "{}p{}o{}o{}t{}a{}r{}e{}y{}o{}u{}{}{}".format(int(scoreData["100_count"]) + int(scoreData["300_count"]),
                                                      scoreData["50_count"], scoreData["gekis_count"],
                                                      scoreData["katus_count"], scoreData["misses_count"],
                                                      scoreData["beatmap_md5"], scoreData["max_combo"],
                                                      "True" if int(scoreData["full_combo"]) == 1 else "False",
                                                      scoreData["username"], scoreData["score"], rank,
                                                      scoreData["mods"], "True"))

    if not rawReplay:
        if scoreData["mods"] & mods.RELAX:
            fileName = f".data/rx_replays/replay_{scoreID}.osr"
        else:
            fileName = f".data/replays/replay_{scoreID}.osr"

        # Make sure raw replay exists
        if not path.isfile(fileName):
            log.warning(f"Replay {scoreID} doesn't exist.")
            return

        # Read raw replay
        with open(fileName, "rb") as f:
            rawReplay = f.read()

    # Add headers (convert to full replay)
    fullReplay = binaryHelper.binaryWrite([
        [scoreData["play_mode"], dataTypes.byte],
        [20150414, dataTypes.uInt32],
        [scoreData["beatmap_md5"], dataTypes.string],
        [scoreData["username"], dataTypes.string],
        [magicHash, dataTypes.string],
        [scoreData["300_count"], dataTypes.uInt16],
        [scoreData["100_count"], dataTypes.uInt16],
        [scoreData["50_count"], dataTypes.uInt16],
        [scoreData["gekis_count"], dataTypes.uInt16],
        [scoreData["katus_count"], dataTypes.uInt16],
        [scoreData["misses_count"], dataTypes.uInt16],
        [scoreData["score"], dataTypes.uInt32],
        [scoreData["max_combo"], dataTypes.uInt16],
        [scoreData["full_combo"], dataTypes.byte],
        [scoreData["mods"], dataTypes.uInt32],
        [0, dataTypes.byte],
        [0x89F7FF5F7B58000 + (int(scoreData["time"]) * 10000000), dataTypes.uInt64],
        [rawReplay, dataTypes.rawReplay],
        [0, dataTypes.uInt32],
        [0, dataTypes.uInt32],
    ])

    # Return full replay
    return fullReplay
