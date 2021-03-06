from os import path

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin
from PIL import Image

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from common import generalUtils
from objects import glob
from common.sentry import sentry

MODULE_NAME = "screenshot"
class handler(requestsManager.asyncRequestHandler):
    """
    Handler for /web/osu-screenshot.php
    """
    @tornado.web.asynchronous
    @tornado.gen.engine
    @sentry.captureTornado
    def asyncPost(self):
        try:
            if glob.debug:
                requestsManager.printArguments(self)

            # Make sure screenshot file was passed
            if "ss" not in self.request.files:
                raise exceptions.invalidArgumentsException(MODULE_NAME)

            # Check user auth because of sneaky people
            if not requestsManager.checkArguments(self.request.arguments, ["u", "p"]):
                raise exceptions.invalidArgumentsException(MODULE_NAME)
            username = self.get_argument("u")
            password = self.get_argument("p")
            ip = self.getRequestIP()
            userID = userUtils.getID(username)
            if not userUtils.checkLogin(userID, password):
                raise exceptions.loginFailedException(MODULE_NAME, username)

            # Rate limit
            if glob.redis.get(f"lets:screenshot:{userID}"):
                self.write("no")
                return
            glob.redis.set(f"lets:screenshot:{userID}", 1, 60)

            # Get a random screenshot id
            found = False
            screenshotID = ""
            while not found:
                screenshotID = generalUtils.randomString(8)
                if not path.isfile(f"/home/akatsuki/screenshots/{screenshotID}.png"):
                    found = True

            # Write screenshot file to .data folder
            with open(f"/home/akatsuki/screenshots/{screenshotID}.png", "wb") as f:
                f.write(self.request.files["ss"][0]["body"])

            # Add Akatsuki's watermark
            # Disabled for the time being..
            """
            base_screenshot = Image.open(f'/home/akatsuki/screenshots/{screenshotID}.png')
            _watermark = Image.open('../hanayo/static/logos/logo.png')
            watermark = _watermark.resize((_watermark.width // 3, _watermark.height // 3))
            width, height = base_screenshot.size

            transparent = Image.new('RGBA', (width, height), (0,0,0,0))
            transparent.paste(base_screenshot, (0,0))
            transparent.paste(watermark, (width - 330, height - 200), mask=watermark)
            watermark.close()
            transparent.save(f'/home/akatsuki/screenshots/{screenshotID}.png')
            transparent.close()
            """

            # Output
            #log.info("New screenshot ({})".format(screenshotID))

            # Return screenshot link
            self.write(f"{glob.conf.config['server']['servername']}/ss/{screenshotID}.png")
        except exceptions.invalidArgumentsException:
            pass
        except exceptions.loginFailedException:
            pass
