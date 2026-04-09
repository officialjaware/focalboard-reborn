// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

import {toLocale} from './i18n'

describe('toLocale', () => {
    it('returns bare language codes unchanged', () => {
        expect(toLocale('en')).toBe('en')
        expect(toLocale('de')).toBe('de')
        expect(toLocale('fr')).toBe('fr')
        expect(toLocale('ja')).toBe('ja')
    })

    it('normalises hyphen-separated codes to uppercase region', () => {
        expect(toLocale('pt-br')).toBe('pt-BR')
        expect(toLocale('zh-cn')).toBe('zh-CN')
        expect(toLocale('zh-tw')).toBe('zh-TW')
    })

    it('normalises underscore-separated codes to uppercase region', () => {
        expect(toLocale('pt_BR')).toBe('pt-BR')
        expect(toLocale('zh_CN')).toBe('zh-CN')
    })

    it('already-correct tags pass through unchanged', () => {
        expect(toLocale('en-US')).toBe('en-US')
        expect(toLocale('pt-BR')).toBe('pt-BR')
    })
})
