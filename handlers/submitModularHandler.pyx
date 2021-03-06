from typing import Optional, Dict, Union
from collections import OrderedDict
from json import dumps
from sys import exc_info
from traceback import format_exc
from urllib.parse import urlencode

from requests import get
import tornado.gen
import tornado.web

from math import ceil
from time import time
from random import randrange

import secret.achievements.utils
from common.constants import gameModes
from common.constants import mods
from common.constants import akatsukiModes as akatsuki
from common.constants import osuFlags as osu_flags
from common.log import logUtils as log
from common.ripple import userUtils
from common.ripple import scoreUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from constants.exceptions import ppCalcException
from helpers import aeshelper
from helpers import replayHelper
from helpers import leaderboardHelper
from objects import beatmap
from objects import glob
from objects import score
from objects import scoreboard
from objects import relaxboard
from objects import rxscore
from helpers.generalHelper import zingonify
from objects.charts import BeatmapChart, OverallChart
from common import generalUtils

MODULE_NAME = 'submit_modular'
class handler(requestsManager.asyncRequestHandler):
    '''
    Handler for /web/osu-submit-modular.php
    '''
    @tornado.web.asynchronous
    @tornado.gen.engine
    #@sentry.captureTornado
    def asyncPost(self, selector):

        _selector: bool = selector == '-selector'
        start_time: float = time()

        # Akatsuki's score-submission anti-cheat for custom clients.
        _cc_flags:        int = 0      # Base flag, nothing unusual detected.
        _cc_invalid_url:  int = 2 << 0 # Requested to osu-submit-modular.php rather than newer osu-submit-modular-selector.php
        _cc_args_missing: int = 2 << 1 # Required args were not sent (probably "ft" and "x")
        _cc_args_invalid: int = 2 << 2 # Sent additional/invalid arguments (probably known to be used in old clients like "pl" and "bmk"/"bml")

        try:
            # Resend the score in case of unhandled exceptions
            keepSending: bool = True

            # Get request ip
            ip = self.getRequestIP()

            # Print arguments
            if glob.debug:
                requestsManager.printArguments(self)

            # Check arguments
            if not requestsManager.checkArguments(self.request.arguments, ['score', 'iv', 'pass']):
                raise exceptions.invalidArgumentsException(MODULE_NAME)

            # TODO: Maintenance check

            # Get parameters and IP
            scoreDataEnc: Optional[str] = self.get_argument('score', None)
            iv: Optional[str] = self.get_argument('iv', None)
            password: Optional[str] = self.get_argument('pass', None)

            # Get right AES Key
            if 'osuver' in self.request.arguments: aeskey = f'osu!-scoreburgr---------{self.get_argument("osuver")}'
            else: aeskey: str = 'h89f2-890h2h89b34g-h80g134n90133'

            # Get score data
            log.debug('Decrypting score data...')
            scoreData: List[str] = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(':')

            # Fix unicode name
            scoreData[1] = scoreData[1].encode("latin_1").decode("utf-8")
            username: str = scoreData[1].strip()

            # Disable cmyui custom client..
            #if 'cv' in self.request.arguments:
            #	raise exceptions.loginFailedException(MODULE_NAME, username)

            # Login and ban check
            userID: int = userUtils.getID(username)
            # User exists check
            if not userID:
                raise exceptions.loginFailedException(MODULE_NAME, userID)
            # Bancho session/username-pass combo check
            if not userUtils.checkLogin(userID, password, ip):
                raise exceptions.loginFailedException(MODULE_NAME, username)
            # Generic bancho session check
            #if not userUtils.checkBanchoSession(userID):
                # TODO: Ban (see except exceptions.noBanchoSessionException block)
            #	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
            # Ban check
            if userUtils.isBanned(userID):
                raise exceptions.userBannedException(MODULE_NAME, username)
            # Data length check
            if len(scoreData) < 16:
                raise exceptions.invalidArgumentsException(MODULE_NAME)

            # Get restricted
            restricted: bool = userUtils.isRestricted(userID)

            # Create score object and set its data
            s: rxscore.score = rxscore.score() if int(scoreData[13]) & mods.RELAX else score.score()
            s.setDataFromScoreData(scoreData)

            if s.completed == -1:
                # Duplicated score
                log.warning('Duplicated score detected, this is normal right after restarting the server')
                return

            # Set score stuff missing in score data
            s.playerUserID = userID

            # Get beatmap info
            beatmapInfo: beatmap.beatmap = beatmap.beatmap()
            beatmapInfo.setDataFromDB(s.fileMd5)

            # Make sure the beatmap is submitted and updated
            if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
                log.debug('Beatmap is not submitted/outdated/unknown. Score submission aborted.')
                return

            # readme tempfix
            if beatmapInfo.beatmapID == 888412 or beatmapInfo.beatmapID == 888413: return

            if not restricted: # Quick custom-client check.
                if not _selector:
                    _cc_flags |= _cc_invalid_url

                if any(i in self.request.arguments for i in ['bml', 'pl']):
                    log.warning(f'_cc_args_invalid triggered: {username} \n\n{self.request.arguments}\n\n')
                     #_cc_flags |= _cc_args_invalid


            # Increment user playtime.
            length: int = 0
            if s.passed:
                if  not restricted \
                and not any(i in self.request.arguments for i in ['ft', 'x']):
                    _cc_flags |= _cc_args_missing

                #try: # Custom client check based on arguments missing
                #	self.get_argument('ft')
                #	self.get_argument('x')
                #except:
                #	# Custom client check 2
                #	# User did not sent 'ft' and 'x' params
                #	if not restricted:
                #		custom_client |= 2
                length = userUtils.getBeatmapTime(beatmapInfo.beatmapID)
            else:
                length = ceil(int(self.get_argument('ft')) / 1000)

            # Edit length based on mods; this is not done automatically!
            if s.mods & mods.HALFTIME:
                length *= 1.5
            elif any(s.mods & i for i in [mods.DOUBLETIME, mods.NIGHTCORE]):
                length /= 1.5

            userUtils.incrementPlaytime(userID, s.gameMode, length)

            # Calculate PP
            midPPCalcException: Optional[Exception] = None
            try: s.calculatePP()
            except Exception as e:
                # Intercept ALL exceptions and bypass them.
                # We want to save scores even in case PP calc fails
                # due to some rippoppai bugs.
                # I know this is bad, but who cares since I'll rewrite
                # the scores server again.
                log.error('Caught an exception in pp calculation, re-raising after saving score in db.')
                s.pp = 0
                midPPCalcException = e

            # Restrict obvious cheaters™
            if not restricted and s.pp > scoreUtils.getPPLimit(s.gameMode, s.mods & mods.RELAX, s.mods & mods.FLASHLIGHT) and not userUtils.checkWhitelist(userID, akatsuki.RELAX if s.mods & mods.RELAX else akatsuki.VANILLA):
                userUtils.restrict(userID)
                userUtils.appendNotes(userID, f'[GM {s.gameMode}] Restricted from breaking PP limit ({"FL" if s.mods & mods.FLASHLIGHT else ""}{"RX" if s.mods & mods.RELAX else ""}) - {s.pp:.2f}pp.')
                log.warning(f'[GM {s.gameMode}] [{username}](https://akatsuki.pw{"/rx" if s.mods & mods.RELAX else ""}/u/{userID}) restricted from breaking PP limit ({"FL" if s.mods & mods.FLASHLIGHT else ""}{"RX" if s.mods & mods.RELAX else ""}) - **{s.pp:.2f}**pp.', 'auto_restriction')


                """ Some anticheat measures added by Nyo sometime due to solis and I """
                """ pretty irrelevant and slow, might as well not be used.           """

                # if s.gameMode == gameModes.MANIA and s.score > 1000000:
                # 	userUtils.ban(userID)
                # 	userUtils.appendNotes(userID, 'Banned due to mania score > 1000000.')

                # if ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
                # 		or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0) \
                # 		or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0) \
                # 		or ((s.mods & mods.RELAX) > 0 and (s.mods & mods.RELAX2) > 0):
                # 	userUtils.ban(userID)
                # 	userUtils.appendNotes(userID, f'Impossible mod combination ({s.mods}).')

            oldPersonalBestRank: int = 0
            oldPersonalBest: Optional[score.score] = None
            if s.passed:
                # Mass multiaccounters check.
                if userID in glob.cursed and randrange(50, 100) < s.pp // 10:
                    log.error(f"Failed to submit {username}'s ({userID}) {s.pp:.2f} score.. perhaps purposely?", discord='cm')
                    return

                # Right before submitting the score, get the personal best score object (we need it for charts)
                if s.oldPersonalBest > 0:
                    oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
                    if oldPersonalBestRank == 0:
                        oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
                        oldScoreboard.setPersonalBestRank()
                        oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
                    oldPersonalBest = score.score(s.oldPersonalBest, oldPersonalBestRank)

            # Save score in db
            s.saveScoreInDB()

            if not restricted:
                # Custom client detection flags
                if _cc_flags and not userUtils.checkDelayBan(userID):
                    log.warning(f'**[{username}](https://akatsuki.pw/{"rx/" if s.mods & mods.RELAX else ""}u/{userID}) ' \
                                 f'has submitted a score using a custom client.\n\nFlags: {_cc_flags}**', 'custom_client')
                    userUtils.setDelayBan(userID, True)

                # Peppy's client anti-cheat flags
                # The osu! client sends a string of space characters.
                # The amount of spaces signifies the flag bit, 1:1.
                peppy_flags: int = int(scoreData[17].count(' '))
                if peppy_flags not in (osu_flags.Clean, osu_flags.IncorrectModValue) and s.completed > 1 and s.pp > 100: # Don't even bother checking <100pp scores
                    peppy_flags_readable: Optional[str] = generalUtils.osuFlagsReadable(peppy_flags)

                    userUtils.appendNotes(userID, f'-- has received clientside flags: {peppy_flags} [\n{peppy_flags_readable}\n] (cheated score id: {s.scoreID})')
                    log.warning(f'[{username}](https://akatsuki.pw/{"rx/" if s.mods & mods.RELAX else ""}u/{userID}) has recieved ppy flags: **{peppy_flags}**.\n\n**Breakdown**\n{peppy_flags_readable}\n\n**[Replay](https://akatsuki.pw/web/replays/{s.scoreID})**', 'cm')

            # NOTE: Process logging was removed from the client starting from 20180322
            # Save replay for all passed scores
            # Make sure the score has an id as well (duplicated?, query error?)
            if s.passed and s.scoreID > 0:
                if 'score' in self.request.files:
                    # Save the replay if it was provided
                    log.debug(f'Saving replay ({s.scoreID})')
                    replay = self.request.files['score'][0]['body']
                    if s.mods & mods.RELAX:
                        with open(f'.data/rx_replays/replay_{s.scoreID}.osr', 'wb') as f:
                            f.write(replay)
                    else:
                        with open(f'.data/replays/replay_{s.scoreID}.osr', 'wb') as f:
                            f.write(replay)

                elif not restricted: # Restrict if no replay was provided
                    userUtils.restrict(userID)
                    userUtils.appendNotes(userID, 'Restricted due to missing replay while submitting a score.')
                    log.warning(f'**{username}** {userID} has been restricted due to not submitting a replay on map {s.fileMd5}.', 'client_detection')

            # Update beatmap playcount (and passcount)
            beatmap.incrementPlaycount(s.fileMd5, s.passed)

            # Let the api know of this score
            if s.scoreID:
                glob.redis.publish('api:score_submission', s.scoreID)

            # Re-raise pp calc exception after saving score, cake, replay etc
            # so Sentry can track it without breaking score submission
            if midPPCalcException is not None:
                raise ppCalcException(midPPCalcException)

            # If there was no exception, update stats and build score submitted panel
            # Get "before" stats for ranking panel (only if passed)
            if s.passed:
                # Get stats and rank
                if s.mods & mods.RELAX:
                    oldUserData = glob.userStatsCache.rxget(userID, s.gameMode)
                    oldRank = userUtils.rxgetGameRank(userID, s.gameMode)
                else:
                    oldUserData = glob.userStatsCache.get(userID, s.gameMode)
                    oldRank = userUtils.getGameRank(userID, s.gameMode)

            # Always update users stats (total/ranked score, playcount, level, acc and pp)
            # even if not passed

            log.debug(f"[{'R' if s.mods & mods.RELAX else 'V'}] Updating {username}'s stats...")
            if s.mods & mods.RELAX:
                userUtils.rxupdateStats(userID, s)
            else:
                userUtils.updateStats(userID, s)

            # Get "after" stats for ranking panel
            # and to determine if we should update the leaderboard
            # (only if we passed that song)
            if s.passed:
                # Get new stats
                if s.mods & mods.RELAX:
                    maxCombo = 0
                    newUserData = userUtils.getRelaxStats(userID, s.gameMode)
                    glob.userStatsCache.rxupdate(userID, s.gameMode, newUserData)
                else:
                    maxCombo = userUtils.getMaxCombo(userID, s.gameMode)
                    newUserData = userUtils.getUserStats(userID, s.gameMode)
                    glob.userStatsCache.update(userID, s.gameMode, newUserData)

                # Update leaderboard (global and country) if score/pp has changed
                if s.completed == 3 and newUserData['pp'] != oldUserData['pp']:
                    if s.mods & mods.RELAX:
                        leaderboardHelper.rxupdate(userID, newUserData['pp'], s.gameMode)
                        leaderboardHelper.rxupdateCountry(userID, newUserData['pp'], s.gameMode)
                    else:
                        leaderboardHelper.update(userID, newUserData['pp'], s.gameMode)
                        leaderboardHelper.updateCountry(userID, newUserData['pp'], s.gameMode)

            # TODO: Update total hits and max combo
            # Update latest activity
            userUtils.updateLatestActivity(userID)

            # IP log
            userUtils.IPLog(userID, ip)

            # Score submission and stats update done
            log.debug('Score submission and user stats update done!')

            # Score has been submitted, do not retry sending the score if
            # there are exceptions while building the ranking panel
            keepSending: bool = False

            # At the end, check achievements
            if s.passed:
                new_achievements = secret.achievements.utils.unlock_achievements(s, beatmapInfo, newUserData)

            # Output ranking panel only if we passed the song
            # and we got valid beatmap info from db
            if beatmapInfo is not None and beatmapInfo and s.passed:
                log.debug('Started building ranking panel.')

                if s.mods & mods.RELAX: # Relax
                    # Trigger bancho stats cache update
                    glob.redis.publish('peppy:update_rxcached_stats', userID)

                    newScoreboard = relaxboard.scoreboard(username, s.gameMode, beatmapInfo, False)
                    newScoreboard.setPersonalBestRank()
                    personalBestID = newScoreboard.getPersonalBestID()
                    assert personalBestID is not None
                    currentPersonalBest: rxscore.score = rxscore.score(personalBestID, newScoreboard.personalBestRank)

                    # Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
                    rankInfo = leaderboardHelper.rxgetRankInfo(userID, s.gameMode)

                else: # Vanilla
                    # Trigger bancho stats cache update
                    glob.redis.publish('peppy:update_cached_stats', userID)

                    newScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
                    newScoreboard.setPersonalBestRank()
                    personalBestID = newScoreboard.getPersonalBestID()
                    assert personalBestID is not None
                    currentPersonalBest: score.score = score.score(personalBestID, newScoreboard.personalBestRank)

                    # Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
                    rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode)

                output = '\n'.join(zingonify(x) for x in [
                    OrderedDict([
                        ('beatmapId', beatmapInfo.beatmapID),
                        ('beatmapSetId', beatmapInfo.beatmapSetID),
                        ('beatmapPlaycount', beatmapInfo.playcount + 1),
                        ('beatmapPasscount', beatmapInfo.passcount + (s.completed == 3)),
                        ('approvedDate', '')
                    ]),
                    BeatmapChart(
                        oldPersonalBest if s.completed == 3 else currentPersonalBest,
                        currentPersonalBest if s.completed == 3 else s,
                        beatmapInfo.beatmapID,
                    ),
                    OverallChart(
                        userID, oldUserData, newUserData, maxCombo, s, new_achievements, oldRank, rankInfo['currentRank']
                    )
                ])

                """ Globally announcing plays. """
                annmsg: Optional[str] = None

                if s.completed == 3 and not restricted:
                    if newScoreboard.personalBestRank == 1 and beatmapInfo.rankedStatus != rankedStatuses.PENDING: # Send message to #announce if the map is ranked and we're rank #1.
                        if s.pp > 350. if s.mods & mods.RELAX else 250.:
                            annmsg = f'[{"R" if s.mods & mods.RELAX else "V"}] [https://osu.ppy.sb/u/{userID} {username}] 在 [https://osu.ppy.sh/b/{beatmapInfo.beatmapID} {beatmapInfo.songName}] ({gameModes.getGamemodeFull(s.gameMode)}) 中取得了第一名 - {s.pp:.2f}pp'

                        # Add the #1 to the database. Yes this is spaghetti.
                        scoreUtils.newFirst(s.scoreID, userID, s.fileMd5, s.gameMode, s.mods & mods.RELAX)

                        # Is the map the contest map? Try to fetch it by beatmapID, rx, and gamemode.
                        contest = glob.db.fetch('SELECT id, relax, gamemode FROM competitions WHERE map = %s AND relax = %s AND gamemode = %s', [beatmapInfo.beatmapID, int(s.mods & mods.RELAX), s.gameMode]) # TODO: scoreUtils

                        if contest is not None: # TODO: Add contest stuff to scoreUtils
                            glob.db.execute('UPDATE competitions SET leader = %s WHERE id = %s', [userID, contest['id']])
                            annmsg = f'[{"R" if s.mods & mods.RELAX else "V"}] [https://osu.ppy.sb/u/{userID} {username}] 夺取了 [https://osu.ppy.sh/b/{beatmapInfo.beatmapID} {beatmapInfo.songName}]! ({gameModes.getGamemodeFull(s.gameMode)}) 的第一名 - {s.pp:.2f}pp'

                    # TODO: other gamemodes?

                    if not s.gameMode and s.pp > glob.topPlays[bool(s.mods & mods.RELAX)] and userUtils.noPPLimit(userID, s.mods & mods.RELAX):
                        annmsg = f"[{'R' if s.mods & mods.RELAX else 'V'}] [https://osu.ppy.sb/u/{userID} {username}] 在 [https://osu.ppy.sh/b/{beatmapInfo.beatmapID} {beatmapInfo.songName}] ({gameModes.getGamemodeFull(s.gameMode)}) 中打破了服务器最高pp记录 - {s.pp:.2f}pp"

                    # If the message has been set to something other than None, send it to #announce.
                    if annmsg:
                        get(f'{glob.conf.config["server"]["banchourl"]}/api/v1/fokabotMessage?{urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": annmsg}, encoding="utf-8")}')

                # Write message to client
                self.write(output)
            else:
                # No ranking panel, send just 'ok'
                self.write('ok')

            # Send username change request to bancho if needed
            # (key is deleted bancho-side)
            newUsername = glob.redis.get(f'ripple:change_username_pending:{userID}')
            if newUsername:
                log.debug(f'Sending username change request for user {userID} to Bancho')
                glob.redis.publish('peppy:change_username', dumps({
                    'userID': userID,
                    'newUsername': newUsername.decode('utf-8')
                }))

            # Datadog stats
            glob.dog.increment(f'{glob.DATADOG_PREFIX}.submitted_scores')

            log.info(f'Score took {int(1000 * (time() - start_time))}ms.')
        except exceptions.invalidArgumentsException:
            pass
        except exceptions.loginFailedException:
            self.write('error: pass')
        except exceptions.userBannedException:
            self.write('error: ban')
        except exceptions.noBanchoSessionException:
            # We don't have an active bancho session.
            # Don't ban the user but tell the client to send the score again.
            # Once we are sure that this error doesn't get triggered when it
            # shouldn't (eg: bancho restart), we'll ban users that submit
            # scores without an active bancho session.
            # We only log through schiavo atm (see exceptions.py).
            self.set_status(408)
            self.write('error: pass')
        except:
            # Try except block to avoid more errors
            try:
                log.error(f'Unknown error in {MODULE_NAME}!\n```{exc_info()}\n{format_exc()}```')
                if glob.sentry: yield tornado.gen.Task(self.captureException, exc_info=True)
            except: pass

            # Every other exception returns a 408 error (timeout)
            # This avoids lost scores due to score server crash
            # because the client will send the score again after some time.
            if keepSending:
                self.set_status(408)
