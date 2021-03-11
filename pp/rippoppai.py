"""
oppai interface for ripple 2 / LETS
"""
from json import loads, JSONDecodeError
from os import name
from subprocess import run, PIPE

from common.constants import gameModes
from common.constants import mods
from common.log import logUtils as log
from common.ripple import scoreUtils
from constants import exceptions
from helpers import mapsHelper

# constants
MODULE_NAME = "rippoppai"
UNIX = True if name == "posix" else False

def fixPath(command):
    """
    Replace / with \\ if running under WIN32

    commnd -- command to fix
    return -- command with fixed paths
    """
    if UNIX:
        return command
    return command.replace("/", "\\")


class OppaiError(Exception):
    def __init__(self, error):
        self.error = error

class oppai:
    """
    Oppai cacalculator
    """
    # __slots__ = ["pp", "score", "acc", "mods", "combo", "misses", "stars", "beatmap", "map"]

    def __init__(self, __beatmap, __score = None, acc = 0, mods = 0, tillerino = False):
        """
        Set oppai params.

        __beatmap -- beatmap object
        __score -- score object
        acc -- manual acc. Used in tillerino-like bot. You don't need this if you pass __score object
        mods -- manual mods. Used in tillerino-like bot. You don't need this if you pass __score object
        tillerino -- If True, self.pp will be a list with pp values for 100%, 99%, 98% and 95% acc. Optional.
        """
        # Default values
        self.pp = None
        self.score = None
        self.acc = 0
        self.mods = 0
        self.combo = -1
        self.misses = 0
        self.stars = 0
        self.tillerino = tillerino

        # Beatmap object
        self.beatmap = __beatmap

        # If passed, set everything from score object
        if __score:
            self.score = __score
            self.acc = self.score.accuracy * 100
            self.mods = self.score.mods
            self.combo = self.score.maxCombo
            self.misses = self.score.cMiss
            self.gameMode = self.score.gameMode
        else:
            # Otherwise, set acc and mods from params (tillerino)
            self.acc = acc
            self.mods = mods
            if self.beatmap.starsStd > 0:
                self.gameMode = gameModes.STD
            elif self.beatmap.starsTaiko > 0:
                self.gameMode = gameModes.TAIKO
            else:
                self.gameMode = None

        # Calculate pp
        log.debug("oppai ~> Initialized oppai diffcalc")
        self.calculatePP()

    @staticmethod
    def _runOppaiProcess(command):
        log.debug(f"oppai ~> running {command}")
        process = run(f"{command} -ojson", shell=True, stdout=PIPE, stderr=PIPE)
        try:
            output = loads(process.stdout.decode("utf-8", errors="ignore"))
            if "code" not in output or "errstr" not in output:
                raise OppaiError("No code in json output")
            if output["code"] != 200:
                raise OppaiError(f"oppai error {output['code']}: {output['errstr']}")
            if "pp" not in output or "stars" not in output:
                raise OppaiError("No pp/stars entry in oppai json output")
            pp = output["pp"]
            stars = output["stars"]

            log.debug(f"oppai ~> full output: {output}")
            log.debug(f"oppai ~> pp: {pp}, stars: {stars}")
        except (JSONDecodeError, IndexError, OppaiError) as e:
            raise OppaiError(e)
        return pp, stars

    def calculatePP(self):
        """
        Calculate total pp value with oppai and return it

        return -- total pp
        """
        # Set variables
        self.pp = None
        try:
            # Build .osu map file path
            mapFile = mapsHelper.cachedMapPath(self.beatmap.beatmapID)
            log.debug(f"oppai ~> Map file: {mapFile}")
            mapsHelper.cacheMap(mapFile, self.beatmap)

            # Use only mods supported by oppai
            modsFixed = self.mods & 6111#5983

            # Check gamemode
            if self.gameMode != gameModes.STD and self.gameMode != gameModes.TAIKO:
                raise exceptions.unsupportedGameModeException()

            command = f"./pp/oppai-ng/oppai {mapFile}"
            if not self.tillerino:
                # force acc only for non-tillerino calculation
                # acc is set for each subprocess if calculating tillerino-like pp sets
                if self.acc > 0:
                    command += " {acc:.2f}%".format(acc=self.acc)
            # 不是只有 TD
            notSingleTD = not (self.mods == 4)
            if self.mods > 0 and notSingleTD:
                command += " +{mods}".format(mods=scoreUtils.readableMods(modsFixed))
                # 去除 TD nerf
                command = command.replace("TD", "")
            if self.combo > 0:
                command += " {combo}x".format(combo=self.combo)
            if self.misses > 0:
                command += " {misses}xm".format(misses=self.misses)
            if self.gameMode == gameModes.TAIKO:
                command += " -taiko"
            command += " -ojson"

            # Calculate pp
            if not self.tillerino:
                # self.pp, self.stars = self._runOppaiProcess(command)
                temp_pp, self.stars = self._runOppaiProcess(command)
                if (self.gameMode == gameModes.TAIKO and self.beatmap.starsStd > 0 and temp_pp > 800) or \
                    self.stars > 50:
                    # Invalidate pp for bugged taiko converteds and bugged inf pp std maps
                    self.pp = 0
                elif self.mods & mods.RELAX: # Hardcoded pp changes.
                    if self.beatmap.beatmapID in [
                        1808605,  # Louder than steel [ok this is epic]
                        1962833   # Akatsuki compilation [ok this is akatsuki]
                        ]: temp_pp *= 0.85
                    elif self.beatmap.beatmapID in [
                        1821147   # over the top [Above the stars]
                        ]: temp_pp *= 0.70
                    elif self.beatmap.beatmapID in [
                        1844776   # Just press F [Parkour's ok this the epic]
                        ]: temp_pp *= 0.60
                    elif self.beatmap.beatmapID in [
                        1777768,  # Hardware Store [skyapple mode]
                        11336447, # Honesty [DISHONEST]
                        2079597   # Honesty [RIGHTEOUSNESS OF MORALITY]
                        ]: temp_pp *= 0.90
                elif self.beatmap.beatmapID == 1517355: # Marisa wa Taihen.. [YOLO]
                    temp_pp *= 0.65

                self.pp = temp_pp
            else:
                pp_list = []
                for acc in [100, 99, 98, 95]:
                    temp_command = command
                    temp_command += " {acc:.2f}%".format(acc=acc)
                    pp, self.stars = self._runOppaiProcess(temp_command)

                    # If this is a broken converted, set all pp to 0 and break the loop
                    if self.gameMode == gameModes.TAIKO and self.beatmap.starsStd > 0 and pp > 800:
                        pp_list = [0., 0., 0., 0.]
                        break

                    elif self.mods & mods.RELAX: # Hardcoded pp changes.
                        if self.beatmap.beatmapID in [
                            1808605,  # Louder than steel [ok this is epic]
                            1962833   # Akatsuki compilation [ok this is akatsuki]
                            ]: pp *= 0.85
                        elif self.beatmap.beatmapID in [
                            1821147   # over the top [Above the stars]
                            ]: pp *= 0.70
                        elif self.beatmap.beatmapID in [
                            1844776   # Just press F [Parkour's ok this the epic]
                            ]: pp *= 0.60
                        elif self.beatmap.beatmapID in [
                            1777768,  # Hardware Store [skyapple mode]
                            11336447, # Honesty [DISHONEST]
                            2079597   # Honesty [RIGHTEOUSNESS OF MORALITY]
                            ]: pp *= 0.90

                    elif self.beatmap.beatmapID == 1517355: # Marisa wa Taihen.. [YOLO]
                        pp *= 0.65

                    pp_list.append(pp)
                self.pp = pp_list

            log.debug(f"oppai ~> Calculated PP: {self.pp}, stars: {self.stars}")
        except OppaiError as e:
            log.error(f"oppai ~> oppai-ng error! {str(e)}")
            self.pp = 0
        except exceptions.osuApiFailException:
            log.error("oppai ~> osu!api error!")
            self.pp = 0
        except exceptions.unsupportedGameModeException:
            log.error("oppai ~> Unsupported gamemode")
            self.pp = 0
        except Exception as e:
            log.error(f"oppai ~> Unhandled exception: {str(e)}")
            self.pp = 0
            raise
        finally:
            log.debug(f"oppai ~> Shutting down, pp = {self.pp}")
