// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.
import React, {FC} from 'react'
import {useIntl} from 'react-intl'

import {Block} from '../../blocks/block'
import mutator from '../../mutator'
import {Utils} from '../../utils'
import IconButton from '../../widgets/buttons/iconButton'
import DeleteIcon from '../../widgets/icons/delete'
import OptionsIcon from '../../widgets/icons/options'
import Menu from '../../widgets/menu'
import MenuWrapper from '../../widgets/menuWrapper'
import {getUser} from '../../store/users'
import {useAppSelector} from '../../store/hooks'
import Tooltip from '../../widgets/tooltip'
import GuestBadge from '../../widgets/guestBadge'

import './comment.scss'

type Props = {
    comment: Block
    userId: string
    userImageUrl: string
    readonly: boolean
}

const Comment: FC<Props> = (props: Props) => {
    const {comment, userId, userImageUrl} = props
    const intl = useIntl()
    const user = useAppSelector(getUser(userId))
    const date = new Date(comment.createAt)

    const isAction = comment.title.trim().startsWith('/me ')
    const displayTitle = isAction ? comment.title.trim().slice(4) : comment.title
    const html = Utils.htmlFromMarkdown(displayTitle)
    // Strip outer <p>...</p> so action text renders inline with the username
    const actionHtml = isAction ? (html || '').replace(/^<p>([\s\S]*)<\/p>$/, '$1') : ''

    const optionsMenu = !props.readonly && (
        <MenuWrapper>
            <IconButton icon={<OptionsIcon/>}/>
            <Menu position='left'>
                <Menu.Text
                    icon={<DeleteIcon/>}
                    id='delete'
                    name={intl.formatMessage({id: 'Comment.delete', defaultMessage: 'Delete'})}
                    onClick={() => mutator.deleteBlock(comment)}
                />
            </Menu>
        </MenuWrapper>
    )

    if (isAction) {
        return (
            <div
                key={comment.id}
                className='Comment comment comment-action'
            >
                <div className='comment-header'>
                    <img
                        className='comment-avatar'
                        src={userImageUrl}
                    />
                    <GuestBadge show={user?.is_guest}/>
                    <Tooltip title={Utils.displayDateTime(date, intl)}>
                        <div className='comment-date'>
                            {Utils.relativeDisplayDateTime(date, intl)}
                        </div>
                    </Tooltip>
                    {optionsMenu}
                </div>
                <div className='comment-text comment-action-text'>
                    <span className='comment-username'>{user?.username}</span>
                    {' '}
                    <span dangerouslySetInnerHTML={{__html: actionHtml}}/>
                </div>
            </div>
        )
    }

    return (
        <div
            key={comment.id}
            className='Comment comment'
        >
            <div className='comment-header'>
                <img
                    className='comment-avatar'
                    src={userImageUrl}
                />
                <div className='comment-username'>{user?.username}</div>
                <GuestBadge show={user?.is_guest}/>

                <Tooltip title={Utils.displayDateTime(date, intl)}>
                    <div className='comment-date'>
                        {Utils.relativeDisplayDateTime(date, intl)}
                    </div>
                </Tooltip>

                {optionsMenu}
            </div>
            <div
                className='comment-text'
                dangerouslySetInnerHTML={{__html: html}}
            />
        </div>
    )
}

export default Comment
