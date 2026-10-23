#!/usr/bin/env python3

# ---------------------------------------------------------------------------------------------------- #
# Use of Canadian Geodetic Survey products and data is subject to the Open Government Licence - Canada #
# https://open.canada.ca/en/open-government-licence-canada                                             #
# ---------------------------------------------------------------------------------------------------- #

"""
csrs_ppp_auto.py (modified)
- ZIP ONLY: download and save <rinex_name>_full_output.zip, do NOT extract .sum/.pdf
- More robust for parallel use (e.g., 8 workers):
  * configurable HTTP timeout (default 20s)
  * status polling uses that timeout
  * zip download uses that timeout
  * on ReadTimeout during polling/download: wait and retry instead of crashing
"""

__author__ = 'Justin Farinaccio'
__copyright__ = '© His Majesty the King in Right of Canada, as represented by the Minister of Natural Resources,' \
                ' 2017-2024'
__credits__ = 'Justin Farinaccio'
__email__ = 'geodeticinformation-informationgeodesique@nrcan-rncan.gc.ca'
__license__ = 'Open Government Licence - Canada'
__maintainer__ = 'Justin Farinaccio'
__status__ = 'Production'
__version__ = '1.6.2-ziponly'

import argparse
import datetime
import errno
import os
import shutil
import sys
import time
import webbrowser
import zipfile

try:
    assert sys.version_info >= (3, 5)
except AssertionError:
    sys.exit('ERROR: Must use Python 3.5.x or higher\n\t(see https://www.python.org/)')

try:
    import requests
except ImportError:
    sys.exit('ERROR: Must install Requests library\n\t(see https://requests.readthedocs.io/en/latest/)')

try:
    from requests_toolbelt.multipart.encoder import MultipartEncoder
except ImportError:
    sys.exit('ERROR: Must install Requests Toolbelt library\n\t(see https://toolbelt.readthedocs.io/en/latest/)')

# ----------------
# Arg parsing
# ----------------
parser = argparse.ArgumentParser(
    description='{0}'.format('# ---------------- Using CSRS-PPP via script, version 1.6.2 (ZIP ONLY) ---------------- #'),
    epilog='{0}'.format('# -------------- See script header for complete documentation -------------- #'))

parser.add_argument('--user_name', type=str, required=True, help='User name (email) / Utilisateur (e-mail)')
parser.add_argument('--lang', nargs='?', const=1, default='en', type=str.lower, choices=['en', 'fr'],
                    help='Language / Langue (default="en")')
parser.add_argument('--mode', nargs='?', const=1, default='Static', type=str.capitalize,
                    choices=['Static', 'Statique', 'Kinematic', 'Cinematique', 'Cin\u00e9matique'],
                    help='Processing mode / Mode de traitement (default="Static")')
parser.add_argument('--ref', nargs='?', const=1, default='NAD83', type=str.upper, choices=['NAD83', 'ITRF'],
                    help='Reference frame / Cadre de r\u00e9f\u00e9rence (default="NAD83")')
parser.add_argument('--epoch', nargs='?', const=1, default='CURR', type=str.upper,
                    help='NAD83 epoch / \u00e9poque (format="YYYY-MM-DD") (default="CURR")')
parser.add_argument('--vdatum', nargs='?', const=1, default='CGVD2013', type=str.upper, choices=['CGVD2013', 'CGVD28'],
                    help='Vertical datum / Datum altim\u00e9trique (default="CGVD2013")')
parser.add_argument('--rnx', type=str, required=True,
                    help='Absolute path of RINEX observation file / Chemin d\'acc\u00e8s du fichier d\'observation RINEX')
parser.add_argument('--results_dir', type=str,
                    help='Absolute path of directory in which to save results / Chemin du r\u00e9pertoire de sortie')
parser.add_argument('--email', nargs='?', const=1, default='dummy_email', type=str,
                    help='Send results to this email (default="dummy_email" => download to directory)')
parser.add_argument('--output_pdf', nargs='?', const=1, default='full', type=str.lower, choices=['full', 'lite'],
                    help='PDF solution report content (kept for compatibility; ZIP is always downloaded)')
parser.add_argument('--res', action='store_true',
                    help='Download residuals (flag) (NOTE: ZIP-ONLY workflow typically does not use this)')
parser.add_argument('--get_max', nargs='?', const=1, default=30, type=int,
                    help='Number of 10-second intervals to wait for results (default=30)')
parser.add_argument('--web', action='store_true',
                    help='Visit CSRS-PPP website (flag)')

# NEW: allow adjusting HTTP timeout without editing code
parser.add_argument('--http_timeout', nargs='?', const=1, default=20, type=int,
                    help='Per-request HTTP timeout in seconds (default=20). Increase if you see ReadTimeout.')

args = parser.parse_args()

# Canadian Geodetic Survey domain
domain = 'https://webapp.csrs-scrs.nrcan-rncan.gc.ca'

# Launch CSRS-PPP web page
if args.web:
    try:
        if args.lang == 'en':
            print('Loading CSRS-PPP website...')
        else:
            print('Chargement du site Web SCRS-PPP...')
        time.sleep(3)
        webbrowser.open('{0:s}/geod/tools-outils/ppp.php?locale={1:s}'.format(domain, args.lang), new=2, autoraise=True)
        sys.exit()
    except webbrowser.Error:
        sys.exit('ERROR: Cannot load web page')

# Verify method(s) to return results to user
if args.email == 'dummy_email' and not args.results_dir:
    sys.exit('ERROR: Must provide directory or an email address to receive results')
if args.email != 'dummy_email' and '@' not in args.email:
    sys.exit('ERROR: Please enter valid email')

# Verify date format
if 'CURR' not in args.epoch and 'COUR' not in args.epoch:
    max_date = datetime.date.today()
    try:
        input_date = datetime.datetime.strptime(args.epoch, '%Y-%m-%d').date()
        if input_date < datetime.date(1994, 1, 1):
            sys.exit('ERROR: Invalid epoch: {0:s}\n\tPlease select an epoch that is no earlier than 1994-01-01'.format(
                args.epoch))
    except ValueError:
        sys.exit('ERROR: Invalid epoch: {0:s}\n\tFormat must be: YYYY-MM-DD'.format(args.epoch))

    if input_date > max_date:
        sys.exit('ERROR: Epoch cannot be later than today\'s date:'
                 '\n\tepoch chosen: {0:s}\n\ttoday\'s date: {1}'.format(args.epoch, max_date))

# Verify get_max
if args.get_max < 0:
    sys.exit('ERROR: get_max cannot be negative...')
if 0 <= args.get_max < 30:
    sys.exit('ERROR: As get_max is the number of 10-second intervals to wait for results,'
             '\n\tplease wait at least 5 minutes to receive your results.')
elif args.get_max > 180:
    sys.exit('ERROR: Probably best not to wait more than 30 minutes for your results...')

# Working directory
rinex_file_abspath = os.path.abspath(args.rnx)
(rinex_path, rinex_file) = os.path.split(rinex_file_abspath)

try:
    os.chdir(rinex_path)
except FileNotFoundError:
    sys.exit('ERROR: Cannot access directory {0:s}'.format(rinex_path))

# ----------------
# Local Vars
# ----------------
procstat = None
error = 0
debug = 0

sleepsec = 10          # status poll interval (seconds)
http_timeout = int(args.http_timeout)  # per-request timeout in seconds

request_max = 5
keyid = None

# Residuals support retained, but ZIP-only workflow typically does not request residuals.
num_files = 0

url_to_post_to = '{0:s}/CSRS-PPP/service/submit'.format(domain)
browser_name = 'CSRS-PPP access via Python Browser Emulator'
ppp_access = 'nobrowser_status'

# Ensure splitting up the absolute path produces a file name and not just a directory
if rinex_file is None:
    sys.exit('ERROR: No RINEX file')
(rinex_name, suffix) = os.path.splitext(rinex_file)

print('=> RNX: {0:s} [{1:s}]'.format(rinex_file, rinex_path))

# Initializations
if args.mode == 'Static' or args.mode == 'Statique':
    process_type = 'Static'
else:
    process_type = 'Kinematic'

if args.epoch == 'CURR' or args.epoch == 'COUR':
    nad83_epoch = 'CURR'
else:
    nad83_epoch = args.epoch

if args.ref == 'ITRF':
    if args.vdatum == 'CGVD28':
        print('\nNOTE:\tReference frame of ITRF only allows vertical datum of CGVD2013'
              '\n\tVertical datum set to CGVD2013\n')
        time.sleep(10)
    vdatum = 'cgvd2013'

    if nad83_epoch != 'CURR':
        print('\nNOTE:\tReference frame of ITRF only allows the epoch to be the same as the GPS data'
              '\n\tEpoch set to "CURR"\n')
        time.sleep(10)
        nad83_epoch = 'CURR'
else:
    vdatum = args.vdatum.lower()

# -------------------------------------------------
# Submit / poll / download
# -------------------------------------------------
for request_num in range(request_max):
    print('=> Request_num[{0:d}]'.format(request_num))

    content = {
        'return_email': args.email,
        'cmd_process_type': 'std',
        'ppp_access': ppp_access,
        'language': args.lang,
        'user_name': args.user_name,
        'process_type': process_type,
        'sysref': args.ref,
        'nad83_epoch': nad83_epoch,
        'v_datum': vdatum,
        'rfile_upload': (rinex_file, open(rinex_file, 'rb'), 'text/plain'),
        'output_pdf': args.output_pdf
    }
    mtp_data = MultipartEncoder(fields=content)
    header = {'User-Agent': browser_name, 'Content-Type': mtp_data.content_type, 'Accept': 'text/plain'}

    # NOTE: leaving POST without a timeout to preserve original behavior.
    # If you want, you can also set: requests.post(..., timeout=http_timeout)
    req = requests.post(url_to_post_to, data=mtp_data, headers=header)
    keyid = str(req.text)

    if debug:
        print('Key: {0:s}'.format(req.text))

    if req.text:
        keyid = req.text

        if 'DOCTYPE' in keyid:
            print('=> Keyid has a weird value! [{0:s}]'.format(rinex_name))
            if debug:
                print('{0:s}'.format(keyid))
            print('=> Re-Submit ...')
            continue

        print('=> Keyid: {0:s}'.format(keyid))

        if keyid == 'ERROR [SEVERE]':
            sys.exit('CSRS-PPP not available (try again later)')
        if keyid == 'ERROR [002]':
            sys.exit('*** NOTICE ***\nYou have been blocked from using CSRS-PPP. This block is temporary. Please contact CGS for further information.')

        print('=> Now wait until "Status=done" ...')

        # Loop until "done"
        get_num = 0
        procstat = None
        error = 0

        while not (procstat == 'done' or error == 1):
            get_num += 1

            if get_num > args.get_max:
                print('=> Max number of get [{0:d}] exceeded! Too long! [{1:s}]'.format(args.get_max, rinex_name))
                print('=> Next file ...')
                error = 1
                sys.exit(error)

            # status poll with timeout + retry on ReadTimeout
            try:
                r = requests.get(
                    '{0:s}/CSRS-PPP/service/results/status?id={1:s}'.format(domain, keyid),
                    timeout=http_timeout
                )
            except requests.exceptions.ReadTimeout:
                print('\tStatus[{0:d}]: ReadTimeout (>{1:d}s) -- will retry after {2:d}s'.format(
                    get_num, http_timeout, sleepsec
                ))
                time.sleep(sleepsec)
                continue
            except requests.exceptions.RequestException as e:
                sys.exit('ERROR: RequestException while polling status: {0}'.format(e))

            try:
                status = r.content.decode(encoding='utf-8', errors='strict')
            except UnicodeError:
                sys.exit('ERROR: Problem with status! Try again!')

            status_l = str(status).lower()
            if 'processing' in status_l:
                procstat = 'processing'
                sleepmore = 1
            elif 'done' in status_l:
                procstat = 'done'
                sleepmore = 0
            elif 'error' in status_l:
                procstat = 'error'
                sleepmore = 1
            else:
                procstat = 'Unknown'
                print('*ERR*[{0:d}] ... log content follows ...'.format(get_num))
                print('{0:s}'.format(status))
                sleepmore = 1

            print('\tStatus[{0:d}]: {1:s} [{2:s}]'.format(get_num, procstat, rinex_file))

            if sleepmore:
                print('\t[sleep {0:d} sec]'.format(sleepsec))
                time.sleep(sleepsec)

        # ---------------------------------
        # Get result file 'full_output.zip' (ZIP ONLY)
        # ---------------------------------
        if not error:
            if args.email and not args.results_dir:
                print('=> Email with results sent to {0:s}'.format(args.email))
                sys.exit()

            # Ensure output dir exists
            try:
                os.makedirs(args.results_dir)
            except OSError as e:
                if e.errno != errno.EEXIST:
                    raise

            result_name = 'full_output.zip'
            if os.path.isfile(result_name):
                os.remove(result_name)

            print('=> Get results file: {0:s}'.format(result_name))

            for dl_try in range(args.get_max):
                try:
                    r = requests.get(
                        '{0:s}/CSRS-PPP/service/results/file?id={1:s}'.format(domain, keyid),
                        timeout=http_timeout
                    )
                except requests.exceptions.ReadTimeout:
                    print('=> Download ReadTimeout (>{0:d}s) -- retry after {1:d}s (try {2:d})'.format(
                        http_timeout, sleepsec, dl_try
                    ))
                    time.sleep(sleepsec)
                    continue
                except requests.exceptions.RequestException as e:
                    sys.exit('ERROR: RequestException while downloading zip: {0}'.format(e))

                with open(result_name, 'wb') as f:
                    f.write(r.content)

                if os.path.isfile(result_name):
                    # Verify zip integrity
                    try:
                        _ = zipfile.ZipFile(result_name).testzip()
                    except zipfile.BadZipFile:
                        print('=> Bad ZIP file on try {0:d}; will retry'.format(dl_try))
                        try:
                            os.remove(result_name)
                        except OSError:
                            pass
                        time.sleep(sleepsec)
                        continue

                    print('=> Integrity[{0:d}]: OK.'.format(dl_try))

                    final_name = rinex_name + '_' + result_name  # e.g., xxxx_full_output.zip
                    if os.path.isfile(final_name):
                        os.remove(final_name)
                    os.rename(result_name, final_name)

                    # Move zip to desired path
                    shutil.move(final_name, '{0}/{1}'.format(args.results_dir, final_name))

                    if args.email != 'dummy_email':
                        print('=> Email with results sent to {0:s}'.format(args.email))

                    # ZIP ONLY: stop here (do not extract .sum/.pdf; do not download residuals)
                    sys.exit()
                else:
                    print('** Error: File "{0:s}" not found after write; retrying'.format(result_name))
                    time.sleep(sleepsec)
                    continue

            print('=> Max number of download attempts [{0:d}] exceeded!'.format(args.get_max))
            print('=> RNX: {0:s} [keyid: {1:s}]'.format(rinex_name, keyid))
            error = 1
            sys.exit(error)
        else:
            print('=> NO results! An error occurred while processing!!!')
            print('=> RNX: {0:s} [keyid: {1:s}]'.format(rinex_name, keyid))
            error = 1
            sys.exit(error)

    else:
        print('=> Keyid does *NOT* exist!')
        print('=> Re-Submit ...')
        continue

print('=> Max number of requests [{0:d}] exceeded! [{1:s}]'.format(request_max, rinex_name))
print('=> Next file ...')
sys.exit(1)