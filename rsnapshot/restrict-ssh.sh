#!/bin/bash
#
# Restrict SSH commands
# Rootnode, http://rootnode.net
#
# Copyright (C) 2012 Marcin Hlybin
# All rights reserved.
#

COMMAND_NAME=$1
case "$SSH_ORIGINAL_COMMAND" in  
        *\&*)  
                 echo "Rejected"  
                 ;;  
        *\(*)  
                 echo "Rejected"  
                 ;;  
        *\{*)  
                 echo "Rejected"  
                 ;;  
        *\;*)  
                 echo "Rejected"  
                 ;;  
        *\<*)  
                 echo "Rejected"  
                 ;;  
        *\`*)  
                 echo "Rejected"  
                 ;;  
        $COMMAND_NAME*)  
                 $SSH_ORIGINAL_COMMAND  
                 ;;  
        *)  
                 echo "Rejected"  
                 ;;  
esac  
